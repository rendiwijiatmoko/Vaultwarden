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
        case let .transport(url, code, description):
            let endpoint = [url.host, url.path.isEmpty ? nil : url.path]
                .compactMap { $0 }
                .joined()
            return "Could not reach \(endpoint) (URL error \(code)): \(description)"
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

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
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
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
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
            let (url, response) = try await session.download(for: request)
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
