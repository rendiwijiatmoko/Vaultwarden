import BitwardenSdk
import XCTest
@testable import vaultwardenApp

/// Runs against the actual UniFFI library on both macOS and iOS. No server,
/// Keychain, or stored account is used: these are public synthetic test vectors.
@MainActor
final class MacPlatformTests: XCTestCase {
    func testSDKPBKDF2AuthenticationMatchesKnownAnswer() async throws {
        let provider = BitwardenSDKCryptoProvider()
        for email in ["test@bitwarden.com", "TEST@bitwarden.com", " test@bitwarden.com"] {
            let hash = try await provider.authenticationHash(
                email: email,
                masterPassword: "asdfasdf",
                kdf: SDKFixture.kdf
            )
            XCTAssertEqual(hash, "wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=")
        }
    }

    func testSDKArgon2idAuthenticationMatchesKnownAnswer() async throws {
        let hash = try await BitwardenSDKCryptoProvider().authenticationHash(
            email: "test_salt",
            masterPassword: "asdfasdf",
            kdf: KDFConfiguration(type: .argon2id, iterations: 4, memory: 32, parallelism: 2)
        )
        XCTAssertEqual(hash, "PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ=")
    }

    func testSDKUnwrapsKnownVaultUserKey() async throws {
        let userKey = try await SDKFixture.unwrapUserKey()
        XCTAssertEqual(userKey.count, 64)
        XCTAssertEqual(userKey.base64EncodedString(), SDKFixture.userKey)
    }

    func testSDKRejectsIncorrectMasterPassword() async throws {
        do {
            _ = try await SDKFixture.unwrapUserKey(password: "incorrect-master-password")
            XCTFail("A wrong password must not unlock the fixture's authenticated user key")
        } catch let error as VaultCryptoError {
            guard case .sdkFailure = error else {
                return XCTFail("Expected SDK authentication failure; received \(error)")
            }
        }
    }

    func testSDKCipherRoundTripAcrossIndependentClients() async throws {
        let userKey = try await SDKFixture.unwrapUserKey()
        let folderID = "b01ad01f-3423-4e05-8338-612a9d2da01a"
        let item = VaultItem(
            id: UUID(uuidString: "128607c4-ec7e-41ca-aa38-9b277736483d")!,
            name: "Native SDK · 登录",
            username: "person@example.com",
            password: "test-only secret 🔐 123!",
            uri: "https://example.com/sign-in",
            additionalURIs: ["https://accounts.example.com"],
            notes: "Line one\nLine two",
            isFavorite: true,
            totpSecret: "JBSWY3DPEHPK3PXP",
            customFields: [VaultCustomField(name: "Recovery code", value: "synthetic-backup-code", type: .hidden)],
            createdAt: SDKFixture.date,
            updatedAt: SDKFixture.date
        )
        let encrypted = try await BitwardenCipherWriter.encrypt(
            item: item,
            existing: nil,
            folderID: folderID,
            email: SDKFixture.email,
            userKey: userKey,
            credentials: SDKFixture.credentials,
            organizationKeys: [:]
        )
        XCTAssertEqual(encrypted.encryptedFor, SDKFixture.userID)
        XCTAssertNotEqual(encrypted.cipher.name, item.name)
        XCTAssertNotEqual(encrypted.cipher.login?.password, item.password)

        // Reinitialize a distinct SDK instance as the app does after restoring
        // its unlocked key. This also exercises the factory's repository bridge.
        let reader = BitwardenSDKClientFactory.make()
        try await reader.crypto().initializeUserCrypto(
            req: InitUserCryptoRequest(
                userId: SDKFixture.userID,
                kdfParams: .pbkdf2(iterations: 100_000),
                email: SDKFixture.email,
                accountCryptographicState: .v1(privateKey: SDKFixture.privateKey),
                method: .decryptedKey(decryptedUserKey: userKey.base64EncodedString()),
                upgradeToken: nil
            )
        )
        let decrypted = try await reader.vault().ciphers().decrypt(cipher: encrypted.cipher)
        XCTAssertEqual(decrypted.name, item.name)
        XCTAssertEqual(decrypted.login?.username, item.username)
        XCTAssertEqual(decrypted.login?.password, item.password)
        XCTAssertEqual(decrypted.login?.uris?.compactMap(\.uri), item.websiteURIs)
        XCTAssertEqual(decrypted.login?.totp, item.totpSecret)
        XCTAssertEqual(decrypted.notes, item.notes)
        XCTAssertEqual(decrypted.folderId, folderID)
        XCTAssertEqual(decrypted.favorite, item.isFavorite)
        XCTAssertEqual(decrypted.fields?.first?.name, "Recovery code")
        XCTAssertEqual(decrypted.fields?.first?.value, "synthetic-backup-code")
        XCTAssertEqual(decrypted.fields?.first?.type, .hidden)
    }

    func testOTPAuthImportPreservesEncodedAccountAndParameters() throws {
        let url = try XCTUnwrap(URL(string:
            "otpauth://totp/Example%20Service:person%2Bwork%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example%20Service&digits=8&period=60&algorithm=SHA256"
        ))
        let request = try XCTUnwrap(OTPAuthSetupRequest.parse(url))
        XCTAssertEqual(request.name, "Example Service")
        XCTAssertEqual(request.username, "person+work@example.com")
        XCTAssertEqual(request.sourceURL, url)
    }

    func testOTPAuthImportRejectsHOTPAndMissingSecret() throws {
        for value in [
            "otpauth://hotp/Example?secret=JBSWY3DPEHPK3PXP&counter=1",
            "otpauth://totp/Example?issuer=Example",
            "otpauth://totp/Example?secret=%20%20",
            "https://example.com/?secret=JBSWY3DPEHPK3PXP"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(OTPAuthSetupRequest.parse(url), value)
        }
    }
}

private enum SDKFixture {
    // Public upstream vectors from sdk-internal commit
    // 10ba9cbb21cb201988b7e54e68df13678ebcaa5f:
    // crates/bitwarden-crypto/src/keys/master_key.rs and
    // crates/bitwarden-uniffi/swift/integration-tests/Tests/IntegrationTests/Utils.swift.
    // The expected 64-byte user key was independently verified using PBKDF2,
    // HKDF-expand, HMAC-SHA256, and OpenSSL AES-256-CBC against the wrapped key.
    static let email = "test@bitwarden.com"
    nonisolated static let password = "asdfasdfasdf"
    static let userID = "00000000-0000-0000-0000-000000000001"
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let kdf = KDFConfiguration(type: .pbkdf2SHA256, iterations: 100_000, memory: nil, parallelism: nil)
    static let userKey = "w2LO+nwV4oxwswVYCxlOfRUseXfvU03VzvKQHrqeklPgiMZrspUe6sOBToCnDn9Ay0tuCBn8ykVVRb7PWhub2Q=="
    static let protectedUserKey = 
        "2.u2HDQ/nH2J7f5tYHctZx6Q==|NnUKODz8TPycWJA5svexe1wJIz2VexvLbZh2RDfhj5VI3wP8ZkR0Vicvdv7oJRyLI1GyaZDBCf9CTBunRTY"
        + "Uk39DbZl42Rb+Xmzds02EQhc=|rwuo5wgqvTJf3rgwOUfabUyzqhguMYb3sGBjOYqjevc="
    static let privateKey = 
        "2.kmLY8NJVuiKBFJtNd/ZFpA==|qOodlRXER+9ogCe3yOibRHmUcSNvjSKhdDuztLlucs10jLiNoVVVAc+9KfNErLSpx5wmUF1hBOJM8zwVPjg"
        + "QTrmnNf/wuDpwiaCxNYb/0v4FygPy7ccAHK94xP1lfqq7U9+tv+/yiZSwgcT+xF0wFpoxQeNdNRFzPTuD9o4134n8bzacD9DV/WjcrXfRjbBCz"
        + "zuUGj1e78+A7BWN7/5IWLz87KWk8G7O/W4+8PtEzlwkru6Wd1xO19GYU18oArCWCNoegSmcGn7w7NDEXlwD403oY8Oa7ylnbqGE28PVJx+HLPN"
        + "IdSC6YKXeIOMnVs7Mctd/wXC93zGxAWD6ooTCzHSPVV50zKJmWIG2cVVUS7j35H3rGDtUHLI+ASXMEux9REZB8CdVOZMzp2wYeiOpggebJy6MK"
        + "OZqPT1R3X0fqF2dHtRFPXrNsVr1Qt6bS9qTyO4ag1/BCvXF3P1uJEsI812BFAne3cYHy5bIOxuozPfipJrTb5WH35bxhElqwT3y/o/6JWOGg3H"
        + "LDun31YmiZ2HScAsUAcEkA4hhoTNnqy4O2s3yVbCcR7jF7NLsbQc0MDTbnjxTdI4VnqUIn8s2c9hIJy/j80pmO9Bjxp+LQ9a2hUkfHgFhgHxZU"
        + "VaeGVth8zG2kkgGdrp5VHhxMVFfvB26Ka6q6qE/UcS2lONSv+4T8niVRJz57qwctj8MNOkA3PTEfe/DP/LKMefke31YfT0xogHsLhDkx+mS8FC"
        + "c01HReTjKLktk/Jh9mXwC5oKwueWWwlxI935ecn+3I2kAuOfMsgPLkoEBlwgiREC1pM7VVX1x8WmzIQVQTHd4iwnX96QewYckGRfNYWz/zwvWn"
        + "jWlfcg8kRSe+68EHOGeRtC5r27fWLqRc0HNcjwpgHkI/b6czerCe8+07TWql4keJxJxhBYj3iOH7r9ZS8ck51XnOb8tGL1isimAJXodYGzakwk"
        + "tqHAD7MZhS+P02O+6jrg7d+yPC2ZCuS/3TOplYOCHQIhnZtR87PXTUwr83zfOwAwCyv6KP84JUQ45+DItrXLap7nOVZKQ5QxYIlbThAO6eima6"
        + "Zu5XHfqGPMNWv0bLf5+vAjIa5np5DJrSwz9no/hj6CUh0iyI+SJq4RGI60lKtypMvF6MR3nHLEHOycRUQbZIyTHWl4QQLdHzuwN9lv10ouTEvN"
        + "r6sFflAX2yb6w3hlCo7oBytH3rJekjb3IIOzBpeTPIejxzVlh0N9OT5MZdh4sNKYHUoWJ8mnfjdM+L4j5Q2Kgk/XiGDgEebkUxiEOQUdVpePF5"
        + "uSCE+TPav/9FIRGXGiFn6NJMaU7aBsDTFBLloffFLYDpd8/bTwoSvifkj7buwLYM+h/qcnfdy5FWau1cKav+Blq/ZC0qBpo658RTC8ZtseAFDg"
        + "XoQZuksM10hpP9bzD04Bx30xTGX81QbaSTNwSEEVrOtIhbDrj9OI43KH4O6zLzK+t30QxAv5zjk10RZ4+5SAdYndIlld9Y62opCfPDzRy3ubdv"
        + "e4ZEchpIKWTQvIxq3T5ogOhGaWBVYnkMtM2GVqvWV//46gET5SH/MdcwhACUcZ9kCpMnWH9CyyUwYvTT3UlNyV+DlS27LMPvaw7tx7qa+GfNCo"
        + "CBd8S4esZpQYK/WReiS8=|pc7qpD42wxyXemdNPuwxbh8iIaryrBPu8f/DGwYdHTw="

    static var accountKeys: WrappedAccountKeys {
        WrappedAccountKeys(privateKey: privateKey, signedPublicKey: nil, signingKey: nil, securityState: nil)
    }

    static var credentials: StoredSessionCredentials {
        StoredSessionCredentials(
            userID: userID,
            accessToken: "unused-test-token",
            refreshToken: nil,
            tokenType: "Bearer",
            expiresAt: date,
            protectedUserKey: protectedUserKey,
            protectedPrivateKey: privateKey,
            kdf: kdf,
            accountKeys: accountKeys
        )
    }

    static func unwrapUserKey(password: String = SDKFixture.password) async throws -> Data {
        try await BitwardenSDKCryptoProvider().unwrapUserKey(
            userID: userID,
            email: email,
            masterPassword: password,
            kdf: kdf,
            protectedUserKey: protectedUserKey,
            accountKeys: accountKeys
        )
    }
}

/// Exercises the real unlock boundary with an in-memory Keychain stand-in.
/// No credentials, OS authentication UI, or network access are used.
@MainActor
final class UnlockPresentationTests: XCTestCase {
    private let session = AuthenticatedSession(
        accountID: "preview@example.com",
        serverURL: URL(string: "https://example.com")!,
        tokenReference: "unlock-focus-regression"
    )

    func testBackgroundUnlockDoesNotReadProtectedKeyOrUnlockVault() async throws {
        let keychain = UnlockSessionStoreSpy()
        let memory = VaultKeyMemory()
        let service = DefaultVaultwardenService(
            sessionStore: keychain,
            keyMemory: memory,
            unlockPresentationAllowed: { false }
        )
        do {
            try await service.unlock(session: session)
            XCTFail("An inactive app must not start interactive authentication")
        } catch is CancellationError { }
        XCTAssertEqual(keychain.readCount, 0)
        let cachedKey = await memory.load(reference: session.tokenReference)
        XCTAssertNil(cachedKey)
    }

    func testForegroundUnlockStillReadsProtectedKey() async throws {
        let keychain = UnlockSessionStoreSpy()
        let memory = VaultKeyMemory()
        let service = DefaultVaultwardenService(
            sessionStore: keychain,
            keyMemory: memory,
            unlockPresentationAllowed: { true }
        )
        try await service.unlock(session: session)
        XCTAssertEqual(keychain.readCount, 1)
        let cachedKey = await memory.load(reference: session.tokenReference)
        XCTAssertEqual(cachedKey, Data(repeating: 0x42, count: 64))
    }

    func testCancelledQueuedUnlockDoesNotStartAuthentication() async throws {
        let keychain = UnlockSessionStoreSpy()
        let service = DefaultVaultwardenService(
            sessionStore: keychain,
            unlockPresentationAllowed: { true }
        )
        let pendingUnlock = Task { try await service.unlock(session: session) }
        pendingUnlock.cancel()
        do {
            try await pendingUnlock.value
            XCTFail("A cancelled unlock must not open a biometric prompt")
        } catch is CancellationError { }
        XCTAssertEqual(keychain.readCount, 0)
    }
}

private nonisolated final class UnlockSessionStoreSpy: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }

    func loadVaultKey(reference: String, reason: String) throws -> Data {
        lock.withLock { reads += 1 }
        return Data(repeating: 0x42, count: 64)
    }
    func load(reference: String) throws -> StoredSessionCredentials { throw SessionStoreError.notFound }
    func save(_ credentials: StoredSessionCredentials, reference: String) throws { throw SessionStoreError.unexpectedData }
    func delete(reference: String) throws { throw SessionStoreError.unexpectedData }
    func saveVaultKey(_ key: Data, reference: String) throws { throw SessionStoreError.unexpectedData }
}
