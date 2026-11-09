import Foundation

nonisolated protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

nonisolated enum HTTPClientError: LocalizedError, Sendable {
    case transport(url: URL, code: Int, description: String)

    var errorDescription: String? {
        switch self {
        case let .transport(_, rawCode, _):
            // One plain sentence. URL error codes and paths stay out of the UI.
            switch URLError.Code(rawValue: rawCode) {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "The server took too long to respond. Try again."
            case .cannotFindHost, .dnsLookupFailed:
                return "The server couldn't be found. Check the server URL."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return "A secure connection to the server couldn't be established."
            default:
                return "The server couldn't be reached. Try again."
            }
        }
    }

    var allowsOfflineFallback: Bool {
        guard case let .transport(_, rawCode, _) = self else { return false }
        let code = URLError.Code(rawValue: rawCode)
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .dataNotAllowed
        ].contains(code)
    }
}

struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let transferSession: URLSession

    init() {
        session = Self.sharedSession
        transferSession = Self.sharedTransferSession
    }

    // One process-wide session each. Creating a URLSession per client leaks it,
    // because URLSession retains its delegate until invalidated.
    private nonisolated static let sharedSession = makeSession(resourceTimeout: 60)
    // Attachments and Send files can be 100 MB, which needs far more than a minute.
    private nonisolated static let sharedTransferSession = makeSession(resourceTimeout: 60 * 60)

    private nonisolated static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        // Ephemeral: cookies (some reverse proxies need them) and credentials stay
        // in memory, and no response is ever persisted to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Fail fast while offline so the encrypted cache and offline queue take over.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VaultwardenServiceError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HTTPClientError.transport(
                url: request.url ?? error.failingURL ?? URL(fileURLWithPath: "/"),
                code: error.errorCode,
                description: error.localizedDescription
            )
        }
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transferSession.upload(for: request, fromFile: fileURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VaultwardenServiceError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HTTPClientError.transport(
                url: request.url ?? error.failingURL ?? URL(fileURLWithPath: "/"),
                code: error.errorCode,
                description: error.localizedDescription
            )
        }
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        do {
            let (url, response) = try await transferSession.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VaultwardenServiceError.invalidResponse
            }
            return (url, httpResponse)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HTTPClientError.transport(
                url: request.url ?? error.failingURL ?? URL(fileURLWithPath: "/"),
                code: error.errorCode,
                description: error.localizedDescription
            )
        }
    }
}

/// Never forwards a bearer token to another origin and never downgrades to HTTP.
/// Presigned attachment URLs that redirect elsewhere still work without the header.
nonisolated final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated static func redirectedRequest(_ request: URLRequest, from originalURL: URL?) -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return nil }
        var redirected = request
        let sameOrigin = originalURL.map {
            $0.scheme?.lowercased() == url.scheme?.lowercased()
                && $0.host?.lowercased() == url.host?.lowercased()
                && $0.port == url.port
        } ?? false
        if !sameOrigin {
            // A 307/308 resends the body (a refresh token or password hash) as is.
            let method = (request.httpMethod ?? "GET").uppercased()
            guard method == "GET" || method == "HEAD" else { return nil }
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.redirectedRequest(request, from: task.originalRequest?.url)
    }
}

nonisolated enum FormURLEncoder {
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._*"))

    static func encode(_ values: [(String, String)]) -> Data {
        let body = values.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func escape(_ value: String) -> String {
        value
            .addingPercentEncoding(withAllowedCharacters: allowedCharacters)?
            .replacingOccurrences(of: "%20", with: "+") ?? ""
    }
}
