import Foundation
import XCTest
@testable import vaultwardenApp

@MainActor
final class SessionRefreshTests: XCTestCase {
    private let session = AuthenticatedSession(
        accountID: "test@example.com",
        serverURL: URL(string: "https://example.com")!,
        tokenReference: "session-refresh-test"
    )

    func testConcurrentSyncsRotateRefreshTokenOnce() async throws {
        let credentials = RefreshSessionStore()
        let network = RefreshHTTPClient()
        let service = DefaultVaultwardenService(
            httpClient: network,
            sessionStore: credentials,
            cacheStore: RefreshCacheStore()
        )

        async let first: Void = service.refreshEncryptedCache(session: session)
        async let second: Void = service.refreshEncryptedCache(session: session)
        try await first
        try await second

        let refreshCount = await network.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(try credentials.load(reference: session.tokenReference).refreshToken, "new-refresh")
    }

    func testInvalidGrantRequiresSignInWithoutDeletingSavedCredentials() async throws {
        let credentials = RefreshSessionStore()
        let network = RefreshHTTPClient(invalidGrant: true)
        let service = DefaultVaultwardenService(
            httpClient: network,
            sessionStore: credentials,
            cacheStore: RefreshCacheStore()
        )

        do {
            try await service.refreshEncryptedCache(session: session)
            XCTFail("Expected an expired session")
        } catch VaultwardenServiceError.sessionExpired {
            XCTAssertEqual(try credentials.load(reference: session.tokenReference).refreshToken, "old-refresh")
        }
    }

    func testOfflineRefreshCanRetryAfterServerReturns() async throws {
        let credentials = RefreshSessionStore()
        let network = RefreshHTTPClient(offline: true)
        let service = DefaultVaultwardenService(
            httpClient: network,
            sessionStore: credentials,
            cacheStore: RefreshCacheStore()
        )

        do {
            try await service.refreshEncryptedCache(session: session)
            XCTFail("Expected an offline failure")
        } catch is HTTPClientError {
            XCTAssertEqual(try credentials.load(reference: session.tokenReference).refreshToken, "old-refresh")
        }

        await network.setOffline(false)
        try await service.refreshEncryptedCache(session: session)
        XCTAssertEqual(try credentials.load(reference: session.tokenReference).refreshToken, "new-refresh")
    }
}

private final class RefreshSessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials = StoredSessionCredentials(
        userID: nil,
        accessToken: "old-access",
        refreshToken: "old-refresh",
        tokenType: "Bearer",
        expiresAt: .distantPast,
        protectedUserKey: nil,
        protectedPrivateKey: nil,
        kdf: nil,
        accountKeys: nil
    )

    func save(_ value: StoredSessionCredentials, reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        credentials = value
    }

    func load(reference: String) throws -> StoredSessionCredentials {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    func delete(reference: String) throws { throw SessionStoreError.notFound }
    func saveVaultKey(_ key: Data, reference: String) throws { throw SessionStoreError.notFound }
    func loadVaultKey(reference: String, reason: String) throws -> Data { throw SessionStoreError.notFound }
}

private actor RefreshHTTPClient: HTTPClient {
    private(set) var refreshCount = 0
    private let invalidGrant: Bool
    private var offline: Bool

    init(invalidGrant: Bool = false, offline: Bool = false) {
        self.invalidGrant = invalidGrant
        self.offline = offline
    }

    func setOffline(_ value: Bool) { offline = value }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("identity/connect/token") {
            refreshCount += 1
            if offline {
                throw HTTPClientError.transport(
                    url: url,
                    code: URLError.notConnectedToInternet.rawValue,
                    description: "Server unavailable"
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            if invalidGrant {
                return (Data(#"{"error":"invalid_grant"}"#.utf8), response(url, status: 400))
            }
            return (
                Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8),
                response(url, status: 200)
            )
        }
        return (Data("{}".utf8), response(url, status: 200))
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        throw VaultwardenServiceError.invalidResponse
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        throw VaultwardenServiceError.invalidResponse
    }

    private func response(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private struct RefreshCacheStore: VaultCacheStore {
    func save(payload: Data, reference: String) throws {}
    func load(reference: String) throws -> Data { throw VaultCacheError.invalidPayload }
    func delete(reference: String) throws {}
}
