import Foundation
import XCTest
@testable import vaultwardenApp

@MainActor
final class VaultLockTests: XCTestCase {
    private func connectedStore(_ service: LockTestService) async throws -> AppStore {
        let defaults = UserDefaults(suiteName: "vault-lock-\(UUID().uuidString)")!
        let store = AppStore(vaultwardenService: service, settingsDefaults: defaults)
        store.settings.syncOnOpen = false
        try await store.connect(serverURL: "https://example.com", email: "test@example.com", masterPassword: "test")
        return store
    }

    func testLockClearsRecordsAndKeysBeforeServiceLockFinishes() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        store.selectedItemID = store.items.first?.id
        await service.lockGate.pauseNext()

        store.lock(requestAutomaticUnlock: false)

        XCTAssertTrue(store.isLocked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertTrue(store.sends.isEmpty)
        XCTAssertNil(store.selectedItemID)
        let keys = Mirror(reflecting: store).children.first { $0.label == "organizationKeys" }?.value as? [String: String]
        XCTAssertEqual(keys, [:])
        await service.lockGate.waitUntilSuspended()
        await service.lockGate.resume()
    }

    func testSyncFinishingAfterLockCannotRestoreRecords() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        await service.syncGate.pauseNext()
        let sync = Task { await store.sync() }
        await service.syncGate.waitUntilSuspended()

        store.lock()
        await service.syncGate.resume()
        await sync.value

        XCTAssertTrue(store.isLocked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.sends.isEmpty)
    }

    func testOldSyncCannotOverwriteCacheAfterUnlock() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        await service.syncGate.pauseNext()
        let sync = Task { await store.sync() }
        await service.syncGate.waitUntilSuspended()

        store.lock()
        let unlocked = await store.unlock(masterPassword: "test")
        XCTAssertTrue(unlocked)
        XCTAssertEqual(store.items.first?.name, "Restored from cache")
        await service.syncGate.resume()
        await sync.value

        XCTAssertFalse(store.isLocked)
        XCTAssertEqual(store.items.first?.name, "Restored from cache")
    }

    func testRelockDuringCacheRestoreKeepsVaultEmpty() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        store.lock()
        await service.cacheGate.pauseNext()
        let unlock = Task { await store.unlock(masterPassword: "test") }
        await service.cacheGate.waitUntilSuspended()

        store.lock()
        await service.cacheGate.resume()
        let unlocked = await unlock.value

        XCTAssertFalse(unlocked)
        XCTAssertTrue(store.isLocked)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPreparedSaveFromBeforeLockCannotApplyAfterUnlock() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        await service.saveGate.pauseNext()
        let save = Task { await store.save(VaultItem(name: "Stale save", password: "secret")) }
        await service.saveGate.waitUntilSuspended()

        store.lock()
        let unlocked = await store.unlock(masterPassword: "test")
        XCTAssertTrue(unlocked)
        await service.saveGate.resume()
        let saved = await save.value

        XCTAssertFalse(saved)
        XCTAssertEqual(store.items.map(\.name), ["Restored from cache"])
        XCTAssertEqual(store.pendingMutationCount, 0)
    }

    func testFailedUnlockKeepsVaultEmpty() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        store.lock()
        await service.setFailUnlock(true)

        let unlocked = await store.unlock(masterPassword: "incorrect")

        XCTAssertFalse(unlocked)
        XCTAssertTrue(store.isLocked)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSyncRequestedWhileLockedDoesNotLoadRecords() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        store.lock()
        await store.sync()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.isLocked)
    }
}

private actor LockTestGate {
    private var shouldPause = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func pauseNext() { shouldPause = true }

    func suspendIfRequested() async {
        guard shouldPause else { return }
        shouldPause = false
        await withCheckedContinuation { continuation in
            suspended = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}

private actor LockTestService: VaultwardenService {
    let reference = "vault-lock-test-\(UUID().uuidString)"
    let syncGate = LockTestGate()
    let lockGate = LockTestGate()
    let cacheGate = LockTestGate()
    let saveGate = LockTestGate()
    var failUnlock = false
    func setFailUnlock(_ value: Bool) { failUnlock = value }

    private nonisolated static func makeSnapshot(name: String) -> EncryptedVaultSnapshot {
        EncryptedVaultSnapshot(
            revision: Date(), encryptedPayload: Data(),
            decrypted: DecryptedVaultSnapshot(
                items: [VaultItem(name: name, username: "person", password: "secret")],
                folders: [VaultFolder(name: "Personal")], collections: [],
                sends: [SendItem(name: "Private send", kind: .text, deletesAt: .distantFuture)],
                remoteCiphers: [:], folderIDsByName: ["Personal": "folder-id"], remoteSends: [:],
                organizationKeys: ["organization": "secret-key"]
            ), isFromOfflineCache: false
        )
    }
    private let snapshot = makeSnapshot(name: "Server snapshot")
    private let cachedSnapshot = makeSnapshot(name: "Restored from cache")

    func discover(serverURL: URL) async throws -> ServerConfiguration {
        throw CancellationError()
    }

    func login(
        serverURL: URL,
        email: String,
        masterPassword: String,
        twoFactorCode: String?
    ) async throws -> AuthenticatedSession {
        AuthenticatedSession(accountID: email, serverURL: serverURL, tokenReference: reference)
    }

    func pendingLoginRequests(session: AuthenticatedSession) async throws -> [PendingLoginRequest] {
        throw CancellationError()
    }

    func respondToLoginRequest(
        _ request: PendingLoginRequest,
        approved: Bool,
        session: AuthenticatedSession
    ) async throws {
        throw CancellationError()
    }

    func sync(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot {
        await syncGate.suspendIfRequested()
        return snapshot
    }

    func loadCachedVault(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot {
        await cacheGate.suspendIfRequested()
        if failUnlock { throw VaultwardenServiceError.vaultLocked }
        return cachedSnapshot
    }

    func refreshEncryptedCache(session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func clearEncryptedCache(session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func publishAutoFillIndex(snapshot: DecryptedVaultSnapshot, session: AuthenticatedSession) async {
 
    }

    func executeMutation(_ mutation: PreparedVaultMutation, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func rebaseMutation(_ mutation: PreparedVaultMutation, session: AuthenticatedSession) async throws -> PreparedVaultMutation {
        throw CancellationError()
    }

    func prepareSaveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        await saveGate.suspendIfRequested()
        let accountReference = await session.tokenReference
        return PreparedVaultMutation(
            accountReference: accountReference, entity: .cipher,
            entityID: item.id.uuidString, method: "PUT", path: "/ciphers/test",
            projection: .upsertItem(item)
        )
    }

    nonisolated func prepareCipherAction(id: UUID, action: CipherMutationAction, session: AuthenticatedSession) -> PreparedVaultMutation {
        fatalError("Unexpected call in lock regression test")
    }

    func prepareFolderWrite(
        folder: VaultFolder,
        previousName: String?,
        serverID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        throw CancellationError()
    }

    nonisolated func prepareFolderDelete(folder: VaultFolder, serverID: String?, session: AuthenticatedSession) -> PreparedVaultMutation {
        fatalError("Unexpected call in lock regression test")
    }

    func prepareSendWrite(
        item: SendItem,
        password: String?,
        passwordUpdate: SendPasswordUpdate,
        existing: RemoteSendState?,
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        throw CancellationError()
    }

    nonisolated func prepareSendPasswordRemoval(item: SendItem, session: AuthenticatedSession) -> PreparedVaultMutation {
        fatalError("Unexpected call in lock regression test")
    }

    nonisolated func prepareSendDelete(id: UUID, session: AuthenticatedSession) -> PreparedVaultMutation {
        fatalError("Unexpected call in lock regression test")
    }

    func createFileSend(
        item: SendItem,
        password: String?,
        fileURL: URL,
        session: AuthenticatedSession
    ) async throws -> UUID {
        throw CancellationError()
    }

    func downloadAndDecryptSendFile(
        item: SendItem,
        remote: RemoteSendState,
        password: String?,
        session: AuthenticatedSession
    ) async throws -> URL {
        throw CancellationError()
    }

    func uploadAttachment(
        fileURL: URL,
        fileName: String,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        throw CancellationError()
    }

    func downloadAttachment(
        attachment: VaultAttachment,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> URL {
        throw CancellationError()
    }

    func deleteAttachment(
        attachmentID: String,
        cipher: RemoteCipherState,
        session: AuthenticatedSession
    ) async throws {
        throw CancellationError()
    }

    func unlock(session: AuthenticatedSession) async throws {
        if failUnlock { throw VaultwardenServiceError.vaultLocked }
    }

    func unlock(session: AuthenticatedSession, masterPassword: String) async throws {
        if failUnlock { throw VaultwardenServiceError.vaultLocked }
    }

    func lock(session: AuthenticatedSession?) async {
        await lockGate.suspendIfRequested()
    }

    func logout(session: AuthenticatedSession) async throws {
 
    }

    func saveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        throw CancellationError()
    }

    func softDeleteCipher(id: UUID, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func restoreCipher(id: UUID, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func permanentlyDeleteCipher(id: UUID, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func createFolder(name: String, organizationKeys: [String: String], session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func updateFolder(id: String, name: String, organizationKeys: [String: String], session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func deleteFolder(id: String, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func createTextSend(item: SendItem, password: String?, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func updateSend(item: SendItem, existing: RemoteSendState, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }

    func deleteSend(id: UUID, session: AuthenticatedSession) async throws {
        throw CancellationError()
    }
}
