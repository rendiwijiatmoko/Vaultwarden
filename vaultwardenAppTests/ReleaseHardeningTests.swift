import XCTest
@testable import vaultwardenApp

final class ReleaseHardeningTests: XCTestCase {
    func testPBKDF2SHA256KnownAnswer() throws {
        let expected = Data([
            0x12, 0x0f, 0xb6, 0xcf, 0xfc, 0xf8, 0xb3, 0x2c,
            0x43, 0xe7, 0x22, 0x52, 0x56, 0xc4, 0xf8, 0x37,
            0xa8, 0x65, 0x48, 0xc9, 0x2c, 0xcc, 0x35, 0x48,
            0x08, 0x05, 0x98, 0x7c, 0xb7, 0x0b, 0xe1, 0x7b
        ])
        let derived = try PBKDF2SHA256.derive(
            password: Data("password".utf8), salt: Data("salt".utf8),
            iterations: 1, outputByteCount: 32
        )
        XCTAssertEqual(derived, expected)
    }

    func testEncryptedArchiveRoundTripRejectsWrongPassword() throws {
        let item = VaultItem(name: "Example", username: "person", password: "secret", uri: "https://example.com")
        let payload = VaultArchivePayload(
            version: 1, exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [item], folders: [VaultFolder(name: "Personal")],
            excludedOrganizationItems: 0, excludedPasskeys: 0
        )
        let password = "correct horse battery staple"
        let archive = try EncryptedVaultArchive.seal(payload, password: password)
        let opened = try EncryptedVaultArchive.open(archive, password: password)
        XCTAssertEqual(opened.items.first?.password, "secret")
        XCTAssertEqual(opened.folders.first?.name, "Personal")
        XCTAssertThrowsError(try EncryptedVaultArchive.open(archive, password: "wrong password value"))
    }

    func testEncryptedArchiveDetectsModification() throws {
        let payload = VaultArchivePayload(
            version: 1, exportedAt: Date(),
            items: [VaultItem(name: "Tamper test", password: "secret")], folders: [],
            excludedOrganizationItems: 0, excludedPasskeys: 0
        )
        let password = "archive password 123"
        let archive = try EncryptedVaultArchive.seal(payload, password: password)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealedPayload"] as? String)))
        sealed[sealed.startIndex] ^= 0x01
        envelope["sealedPayload"] = sealed.base64EncodedString()
        let modified = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try EncryptedVaultArchive.open(modified, password: password))
    }

    func testVaultProjectionReducerCoversCRUDAndFolderRename() {
        let itemID = UUID()
        let folderID = UUID()
        let sendID = UUID()
        var state = VaultProjectionState(items: [], folders: [], sends: [])
        let item = VaultItem(id: itemID, name: "Login", folder: "Old")
        VaultProjectionReducer.apply(.upsertItem(item), to: &state)
        VaultProjectionReducer.apply(.upsertFolder(folder: VaultFolder(id: folderID, name: "Old"), previousName: nil), to: &state)
        VaultProjectionReducer.apply(.upsertFolder(folder: VaultFolder(id: folderID, name: "New"), previousName: "Old"), to: &state)
        XCTAssertEqual(state.items.first?.folder, "New")
        VaultProjectionReducer.apply(.trashItem(id: itemID, deletedAt: Date()), to: &state)
        XCTAssertNotNil(state.items.first?.deletedAt)
        VaultProjectionReducer.apply(.restoreItem(id: itemID), to: &state)
        XCTAssertNil(state.items.first?.deletedAt)
        let send = SendItem(id: sendID, name: "Text", kind: .text, deletesAt: Date().addingTimeInterval(3600))
        VaultProjectionReducer.apply(.upsertSend(send), to: &state)
        XCTAssertEqual(state.sends.count, 1)
        VaultProjectionReducer.apply(.deleteSend(id: sendID), to: &state)
        VaultProjectionReducer.apply(.deleteItem(id: itemID), to: &state)
        XCTAssertTrue(state.sends.isEmpty)
        XCTAssertTrue(state.items.isEmpty)
    }

    func testSecurityAnalyzerDetectsReusedPasswordsAcrossActiveLogins() {
        let password = "same-password-used-six-times"
        let logins = (0..<6).map {
            VaultItem(name: "Login \($0)", password: password, uri: "https://example.com/\($0)")
        }

        let analyzed = VaultSecurityAnalyzer.analyze(logins)

        XCTAssertEqual(analyzed.count, 6)
        XCTAssertTrue(analyzed.allSatisfy { $0.risks.contains(.reused) })
    }

    func testSecurityAnalyzerIgnoresDeletedArchivedAndEmptyPasswords() {
        let active = VaultItem(name: "Active", password: "unique-active-password")
        var archived = VaultItem(name: "Archived", password: "unique-active-password")
        archived.archivedAt = Date()
        var deleted = VaultItem(name: "Deleted", password: "unique-active-password")
        deleted.deletedAt = Date()
        let empty = VaultItem(name: "Empty", password: "")

        let analyzed = VaultSecurityAnalyzer.analyze([active, archived, deleted, empty])

        XCTAssertTrue(analyzed.allSatisfy { !$0.risks.contains(.reused) })
    }

    func testSyncMutationQueueCoalescesPendingUpdates() async throws {
        let queue = SyncMutationQueue()
        let reference = "tests-\(UUID().uuidString)"
        let itemID = UUID()
        let first = PreparedVaultMutation(
            accountReference: reference, entity: .cipher, entityID: itemID.uuidString,
            method: "PUT", path: "/api/ciphers/\(itemID.uuidString)",
            projection: .upsertItem(VaultItem(id: itemID, name: "First"))
        )
        let second = PreparedVaultMutation(
            accountReference: reference, entity: .cipher, entityID: itemID.uuidString,
            method: "PUT", path: "/api/ciphers/\(itemID.uuidString)",
            projection: .upsertItem(VaultItem(id: itemID, name: "Second"))
        )
        try await queue.enqueue(first)
        try await queue.enqueue(second)
        let pending = try await queue.all(reference: reference)
        XCTAssertEqual(pending.count, 1)
        if case let .upsertItem(item) = try XCTUnwrap(pending.first).projection {
            XCTAssertEqual(item.name, "Second")
        } else {
            XCTFail("Expected upsert projection")
        }
        try await queue.delete(reference: reference)
    }

    func testAutoFillMatchesExactAndSubdomainsOnly() {
        let record = AutoFillCredentialRecord(
            id: "1", name: "Example", username: "person", password: "secret",
            serviceIdentifier: "login.example.com", totpSecret: nil
        )
        XCTAssertTrue(record.matches(serviceIdentifiers: ["login.example.com"]))
        XCTAssertTrue(record.matches(serviceIdentifiers: ["https://example.com/sign-in"]))
        XCTAssertFalse(record.matches(serviceIdentifiers: ["malicious-example.com"]))
    }

    func testAutoFillHonorsPerURIMatchDetection() {
        let record = AutoFillCredentialRecord(
            id: "rules", name: "Rules", username: "person", password: "secret",
            serviceIdentifier: "example.com", totpSecret: nil,
            uriRules: [
                AutoFillURIRule(uri: "https://secure.example.com/login", match: .exact),
                AutoFillURIRule(uri: "accounts.example.net", match: .host),
                AutoFillURIRule(uri: "https://portal.example.org/", match: .startsWith),
                AutoFillURIRule(uri: "^https://[a-z]+\\.example\\.id/login", match: .regularExpression),
                AutoFillURIRule(uri: "ignored.example.xyz", match: .never)
            ]
        )

        XCTAssertEqual(
            record.bestMatch(serviceIdentifiers: ["https://secure.example.com/login"]),
            .exact
        )
        XCTAssertEqual(
            record.bestMatch(serviceIdentifiers: ["https://accounts.example.net/profile"]),
            .host
        )
        XCTAssertEqual(
            record.bestMatch(serviceIdentifiers: ["https://portal.example.org/account"]),
            .startsWith
        )
        XCTAssertEqual(
            record.bestMatch(serviceIdentifiers: ["https://id.example.id/login"]),
            .regularExpression
        )
        XCTAssertNil(record.bestMatch(serviceIdentifiers: ["ignored.example.xyz"]))
    }

    func testPasskeyMatcherUsesRPIDCredentialIDAndUserHandle() {
        let allowedID = Data([1, 2, 3])
        let userHandle = Data([9, 8, 7])
        let matching = AutoFillPasskeyRecord(
            cipherID: "cipher-1", relyingPartyIdentifier: "example.com", userName: "person",
            credentialID: allowedID, userHandle: userHandle, hasCounter: true
        )
        let other = AutoFillPasskeyRecord(
            cipherID: "cipher-2", relyingPartyIdentifier: "other.example", userName: "other",
            credentialID: Data([4]), userHandle: Data([5]), hasCounter: false
        )
        let result = AutoFillPasskeyMatcher.matching(
            [matching, other], relyingPartyIdentifier: "example.com",
            allowedCredentialIDs: [allowedID], userHandle: userHandle
        )
        XCTAssertEqual(result.map(\.cipherID), ["cipher-1"])
    }

    func testVaultTimeoutIntervals() {
        XCTAssertEqual(VaultTimeout.immediately.timeInterval, 0)
        XCTAssertEqual(VaultTimeout.oneMinute.timeInterval, 60)
        XCTAssertEqual(VaultTimeout.fiveMinutes.timeInterval, 300)
        XCTAssertEqual(VaultTimeout.fifteenMinutes.timeInterval, 900)
        XCTAssertNil(VaultTimeout.never.timeInterval)
    }
}
