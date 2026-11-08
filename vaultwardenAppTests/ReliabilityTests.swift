import Foundation
import Testing
@testable import vaultwardenApp

@Suite("KDF parameter bounds")
struct KDFBoundsTests {
    @Test("Accepts the parameters Bitwarden and Vaultwarden actually issue", arguments: [
        KDFConfiguration(type: .pbkdf2SHA256, iterations: 600_000, memory: nil, parallelism: nil),
        KDFConfiguration(type: .pbkdf2SHA256, iterations: 100_000, memory: nil, parallelism: nil),
        KDFConfiguration(type: .argon2id, iterations: 3, memory: 64, parallelism: 4),
        KDFConfiguration(type: .argon2id, iterations: 4, memory: 32, parallelism: 2)
    ])
    func acceptsRealisticParameters(_ configuration: KDFConfiguration) {
        #expect(configuration.isWithinSupportedBounds)
    }

    @Test("Rejects downgrades and memory exhaustion from an untrusted server", arguments: [
        KDFConfiguration(type: .pbkdf2SHA256, iterations: 1, memory: nil, parallelism: nil),
        KDFConfiguration(type: .pbkdf2SHA256, iterations: 50_000_000, memory: nil, parallelism: nil),
        KDFConfiguration(type: .argon2id, iterations: 3, memory: 1_048_576, parallelism: 4),
        KDFConfiguration(type: .argon2id, iterations: 3, memory: 64, parallelism: 1_000),
        KDFConfiguration(type: .argon2id, iterations: 3, memory: nil, parallelism: 4)
    ])
    func rejectsUnsafeParameters(_ configuration: KDFConfiguration) {
        #expect(!configuration.isWithinSupportedBounds)
    }
}

@Suite("Offline queue coalescing")
struct MutationCoalescingTests {
    private let itemID = UUID()

    private func mutation(
        method: String,
        path: String,
        body: Data? = nil,
        projection: VaultMutationProjection? = nil,
        reference: String = "coalescing"
    ) -> PreparedVaultMutation {
        PreparedVaultMutation(
            accountReference: reference, entity: .cipher, entityID: itemID.uuidString.lowercased(),
            method: method, path: path, body: body,
            projection: projection ?? .upsertItem(VaultItem(id: itemID, name: "Item"))
        )
    }

    @Test func trashAfterEditKeepsBothRequests() {
        let edit = mutation(method: "PUT", path: "api/ciphers/1", body: Data("{}".utf8))
        let trash = mutation(method: "PUT", path: "api/ciphers/1/delete", projection: .trashItem(id: itemID, deletedAt: Date()))
        #expect(SyncMutationQueue.coalescing(existing: edit, incoming: trash) == .append)
        #expect(SyncMutationQueue.coalescing(existing: trash, incoming: edit) == .append)
    }

    @Test func repeatedEditsReplaceEachOther() {
        let first = mutation(method: "PUT", path: "api/ciphers/1", body: Data("1".utf8))
        let second = mutation(method: "PUT", path: "api/ciphers/1", body: Data("2".utf8))
        #expect(SyncMutationQueue.coalescing(existing: first, incoming: second) == .replace)
    }

    @Test func permanentDeleteSupersedesAnEdit() {
        let edit = mutation(method: "PUT", path: "api/ciphers/1", body: Data("{}".utf8))
        let delete = mutation(method: "DELETE", path: "api/ciphers/1", projection: .deleteItem(id: itemID))
        #expect(SyncMutationQueue.coalescing(existing: edit, incoming: delete) == .replace)
    }

    @Test func pendingCreateAbsorbsEditsAndVanishesOnDelete() {
        let create = mutation(method: "POST", path: "api/ciphers", body: Data("{}".utf8))
        let edit = mutation(method: "POST", path: "api/ciphers", body: Data("{\"name\":1}".utf8))
        let delete = mutation(method: "DELETE", path: "api/ciphers/1", projection: .deleteItem(id: itemID))
        let bodyless = mutation(method: "PUT", path: "api/ciphers/1/archive", projection: .archiveItem(id: itemID, archivedAt: Date()))
        #expect(SyncMutationQueue.coalescing(existing: create, incoming: edit) == .replace)
        #expect(SyncMutationQueue.coalescing(existing: create, incoming: delete) == .dropBoth)
        #expect(SyncMutationQueue.coalescing(existing: create, incoming: bodyless) == .append)
    }

    @Test func replayOfAnOlderVersionDoesNotRemoveANewerEdit() async throws {
        let queue = SyncMutationQueue()
        let reference = "reliability-\(UUID().uuidString)"
        let first = mutation(method: "PUT", path: "api/ciphers/1", body: Data("1".utf8), reference: reference)
        try await queue.enqueue(first)
        let queued = try await queue.all(reference: reference)
        let sent = try #require(queued.first)

        // A newer edit is coalesced while `sent` is in flight.
        let second = mutation(
            method: "PUT", path: "api/ciphers/1", body: Data("2".utf8),
            projection: .upsertItem(VaultItem(id: itemID, name: "Newer")), reference: reference
        )
        try await queue.enqueue(second)
        try await queue.remove(sent)
        var stale = sent
        stale.lastError = "stale"
        try await queue.update(stale)

        let remaining = try await queue.all(reference: reference)
        try await queue.delete(reference: reference)
        let survivor = try #require(remaining.first)
        #expect(remaining.count == 1)
        #expect(survivor.body == Data("2".utf8))
        #expect(survivor.lastError == nil)
    }
}

@Suite("Sync failure classification")
struct SyncFailureClassificationTests {
    @Test func transportAndServerOutagesAreRetried() {
        let offline = HTTPClientError.transport(
            url: URL(fileURLWithPath: "/"), code: URLError.Code.secureConnectionFailed.rawValue, description: ""
        )
        #expect(VaultSyncEngine.isRetryableSyncFailure(offline))
        #expect(VaultSyncEngine.isRetryableSyncFailure(VaultwardenServiceError.serverRejected(status: 503, message: nil)))
        #expect(VaultSyncEngine.isRetryableSyncFailure(VaultwardenServiceError.sessionExpired))
    }

    @Test func rejectedChangesAreNotRetried() {
        #expect(!VaultSyncEngine.isRetryableSyncFailure(VaultwardenServiceError.serverRejected(status: 400, message: nil)))
        #expect(!VaultSyncEngine.isRetryableSyncFailure(VaultwardenServiceError.serverRejected(status: 403, message: nil)))
    }

    @Test func cancellationIsNeverAFailure() {
        #expect(VaultSyncEngine.isCancellation(CancellationError()))
        #expect(VaultSyncEngine.isCancellation(URLError(.cancelled)))
        #expect(!VaultSyncEngine.isCancellation(URLError(.timedOut)))
    }
}

@Suite("User-facing network errors")
struct NetworkErrorMessageTests {
    @Test(arguments: [
        URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .secureConnectionFailed, .badServerResponse
    ])
    func transportMessagesHideCodesAndPaths(_ code: URLError.Code) throws {
        let error = HTTPClientError.transport(
            url: URL(string: "https://vault.example.com/api/sync")!, code: code.rawValue, description: "raw"
        )
        let message = try #require(error.errorDescription)
        #expect(!message.contains("\(code.rawValue)"))
        #expect(!message.contains("/api/sync"))
        #expect(!message.contains("raw"))
    }

    @Test func serverStatusWithoutMessageIsPlain() {
        let message = VaultwardenServiceError.serverRejected(status: 502, message: nil).errorDescription ?? ""
        #expect(!message.contains("HTTP"))
        #expect(!message.contains("502"))
    }

    @Test func blankServerMessageFallsBackToStatusText() {
        let message = VaultwardenServiceError.serverRejected(status: 403, message: "  ").errorDescription
        #expect(message == VaultwardenServiceError.statusDescription(403))
    }
}

@Suite("Redirect policy")
struct RedirectPolicyTests {
    private func request(_ string: String) -> URLRequest {
        var request = URLRequest(url: URL(string: string)!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func keepsTokenOnSameOrigin() throws {
        let redirected = try #require(RedirectPolicy.redirectedRequest(
            request("https://vault.example.com/api/sync/"), from: URL(string: "https://vault.example.com/api/sync")
        ))
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func stripsTokenOnCrossOriginRedirect() throws {
        let redirected = try #require(RedirectPolicy.redirectedRequest(
            request("https://files.example.net/blob"), from: URL(string: "https://vault.example.com/api/attachment")
        ))
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func refusesDowngradeToHTTP() {
        #expect(RedirectPolicy.redirectedRequest(
            request("http://vault.example.com/api/sync"), from: URL(string: "https://vault.example.com/api/sync")
        ) == nil)
    }
}

@Suite("Generators")
struct GeneratorReliabilityTests {
    @Test func passwordsContainEverySelectedCharacterClass() {
        for _ in 0..<200 {
            let password = PasswordGenerator.password(length: 8, uppercase: true, numbers: true, symbols: true)
            #expect(password.count == 8)
            #expect(password.contains(where: \.isLowercase))
            #expect(password.contains(where: \.isUppercase))
            #expect(password.contains(where: \.isNumber))
            #expect(password.contains { "!@#$%^&*+-=_?".contains($0) })
        }
    }

    @Test func passphraseWordListIsLargeAndUnique() {
        let words = PassphraseWordList.words
        #expect(words.count >= 1_024)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLowercase) })
    }

    @Test func totpMatchesRFC6238ReferenceValue() {
        // RFC 6238 appendix B, SHA-1, T = 59 seconds.
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let date = Date(timeIntervalSince1970: 59)
        #expect(TOTPGenerator.code(secret: secret, date: date, digits: 8) == "94287082")
        #expect(TOTPGenerator.code(secret: secret, date: date) == "287082")
    }

    @Test func totpRejectsEmptyAndInvalidSecrets() {
        #expect(TOTPGenerator.code(secret: "") == nil)
        #expect(TOTPGenerator.code(secret: "otpauth://totp/Example?secret=") == nil)
        #expect(TOTPGenerator.code(secret: "not base32!") == nil)
        #expect(TOTPGenerator.code(secret: "GEZDGNBVGY3TQOJQ", period: 0) == nil)
    }
}

@Suite("Untrusted sync payloads")
struct SyncPayloadHardeningTests {
    @Test func duplicatedOrganizationsDoNotTrap() {
        let organizations = [
            SyncOrganizationDTO(id: "org", name: "First", key: "key-1"),
            SyncOrganizationDTO(id: "org", name: "Second", key: "key-2"),
            SyncOrganizationDTO(id: "other", name: nil, key: nil)
        ]
        let keys = BitwardenVaultPayloadDecoder.organizationKeys(organizations)
        #expect(keys == ["org": "key-1"])
    }
}

@Suite("Temporary files")
struct TemporaryVaultFilesTests {
    @Test func exportNamesUseFixedDigitsAndCalendar() {
        let name = TemporaryVaultFiles.exportFileName(at: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("Vaultwarden-"))
        #expect(name.hasSuffix(".vwvault"))
        #expect(name.unicodeScalars.allSatisfy(\.isASCII))
        #expect(TemporaryVaultFiles.isExport(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test func sweepRemovesPlaintextAndOldExportsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReliabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decrypted = root.appendingPathComponent("DecryptedAttachments", isDirectory: true)
        let staged = root.appendingPathComponent("StagedVaultAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: decrypted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let oldExport = root.appendingPathComponent("Vaultwarden-old.vwvault")
        let unrelated = root.appendingPathComponent("notes.txt")
        try Data().write(to: oldExport)
        try Data().write(to: unrelated)

        TemporaryVaultFiles.removePlaintext(in: root)
        #expect(!FileManager.default.fileExists(atPath: decrypted.path))
        #expect(FileManager.default.fileExists(atPath: staged.path))

        TemporaryVaultFiles.removeAll(in: root)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(atPath: oldExport.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

@MainActor
@Suite("Store persistence and derived lists")
struct StoreReliabilityTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ReliabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func unreadableSettingsKeepAccountAndSecurityChoices() throws {
        try withDefaults { defaults in
            let json = """
            {"serverURL":"https://vault.example.com","email":"person@example.com",
             "sessionReference":"reference","biometricUnlock":true,"vaultTimeout":"5 minutes",
             "theme":"a theme from a newer version"}
            """
            defaults.set(Data(json.utf8), forKey: "vaultwardenApp.settings")
            let settings = AppStore.loadSettings(from: defaults)
            #expect(settings.serverURL == "https://vault.example.com")
            #expect(settings.email == "person@example.com")
            #expect(settings.sessionReference == "reference")
            #expect(settings.biometricUnlock)
            #expect(settings.vaultTimeout == .fiveMinutes)
        }
    }

    @Test func typedEmailIsSavedWhenTheAppLeavesTheForeground() throws {
        try withDefaults { defaults in
            let store = AppStore(settingsDefaults: defaults)
            store.settings.email = "p"
            store.settings.email = "person@example.com"
            store.appDidEnterBackground()
            #expect(AppStore.loadSettings(from: defaults).email == "person@example.com")
        }
    }

    @Test func derivedListsFollowItemChanges() throws {
        try withDefaults { defaults in
            let store = AppStore(settingsDefaults: defaults)
            store.items = [
                VaultItem(name: "A", folder: "Work", isFavorite: true),
                VaultItem(name: "B", type: .card)
            ]
            #expect(store.count(for: .all) == 2)
            #expect(store.favoriteItems.count == 1)
            #expect(store.items(inFolder: "Work").count == 1)
            #expect(store.items(in: .cards).count == 1)

            store.items[0].deletedAt = Date()
            #expect(store.count(for: .all) == 1)
            #expect(store.favoriteItems.isEmpty)
            #expect(store.items(inFolder: "Work").isEmpty)
            #expect(store.items(in: .deleted).count == 1)
        }
    }
}
