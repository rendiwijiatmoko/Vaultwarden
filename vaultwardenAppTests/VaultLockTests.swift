import Foundation
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import vaultwardenApp

@MainActor
final class VaultLockTests: XCTestCase {
    #if os(macOS)
    func testMacDefaultTimeoutAndSavedPreference() throws {
        XCTAssertEqual(AppSettings().vaultTimeout, .fiveMinutes)
        var settings = AppSettings()
        settings.vaultTimeout = .immediately
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).vaultTimeout, .immediately)
    }

    func testMacTimedLockUsesIdleTimeWhileFocusedAndIgnoresFocusLoss() async throws {
        let store = try await connectedStore(LockTestService())
        store.settings.vaultTimeout = .fiveMinutes
        let notifications = NotificationCenter()
        var active = true
        var now = Date()
        var idle: TimeInterval = 0
        let lifecycle = MacVaultLifecycle(
            store: store, applicationIsActive: { active },
            applicationNotifications: notifications,
            workspaceNotifications: NotificationCenter(), screenLockNotifications: NotificationCenter(),
            idleSeconds: { idle }, now: { now }
        )
        active = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertFalse(store.isLocked)
        now = now.addingTimeInterval(600)
        idle = 10 // User is actively working in Terminal.
        lifecycle.checkInactivity()
        XCTAssertFalse(store.isLocked)
        active = true // Idle timeout also applies with the vault in the foreground.
        idle = 300
        lifecycle.checkInactivity()
        XCTAssertTrue(store.isLocked)
        XCTAssertFalse(store.shouldAutomaticallyPromptUnlock)
    }

    func testMacUnlockRestartsIdleGracePeriod() async throws {
        let store = try await connectedStore(LockTestService())
        store.settings.vaultTimeout = .oneMinute
        var now = Date()
        let lifecycle = MacVaultLifecycle(
            store: store, applicationIsActive: { true },
            applicationNotifications: NotificationCenter(),
            workspaceNotifications: NotificationCenter(), screenLockNotifications: NotificationCenter(),
            idleSeconds: { 600 }, now: { now }
        )
        now = now.addingTimeInterval(59)
        lifecycle.checkInactivity()
        XCTAssertFalse(store.isLocked)
        store.lock(requestAutomaticUnlock: false)
        let success = await store.unlock(masterPassword: "test")
        XCTAssertTrue(success)
        now = now.addingTimeInterval(59)
        lifecycle.checkInactivity()
        XCTAssertFalse(store.isLocked)
        now = now.addingTimeInterval(1)
        lifecycle.checkInactivity()
        XCTAssertTrue(store.isLocked)
    }

    func testMacImmediateAndSystemSleepStillLock() async throws {
        let store = try await connectedStore(LockTestService())
        store.settings.vaultTimeout = .immediately
        var active = true
        let notifications = NotificationCenter()
        let workspace = NotificationCenter()
        let lifecycle = MacVaultLifecycle(
            store: store, applicationIsActive: { active },
            applicationNotifications: notifications, workspaceNotifications: workspace,
            screenLockNotifications: NotificationCenter(), idleSeconds: { 0 }
        )
        active = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(store.isLocked)
        active = true
        let success = await store.unlock(masterPassword: "test")
        XCTAssertTrue(success)
        store.settings.vaultTimeout = .never
        lifecycle.checkInactivity()
        XCTAssertFalse(store.isLocked)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(store.isLocked)
    }
    #endif

    func testQuickCopyRejectsLockedArchivedAndRestrictedItems() async throws {
        let store = try await connectedStore(LockTestService())
        var item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(store.canCopyLoginPassword(item))
        item.organization = "restricted-organization"
        XCTAssertFalse(store.canCopyLoginPassword(item))
        item.totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        item.customFields = [VaultCustomField(name: "Hidden", value: "secret", type: .hidden),
                             VaultCustomField(name: "Linked", value: "password", type: .linked)]
        let restricted = store.quickCopyFields(for: item)
        XCTAssertTrue(restricted.contains { $0.id == "username" })
        XCTAssertFalse(restricted.contains { $0.isSensitive })
        item.organization = nil
        item.archivedAt = Date()
        XCTAssertFalse(store.canCopyLoginPassword(item))
        item.archivedAt = nil
        store.lock(requestAutomaticUnlock: false)
        XCTAssertFalse(store.canCopyLoginPassword(item))
        XCTAssertTrue(store.quickCopyFields(for: item).isEmpty)
    }
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

    func testSaveRecordsPreviousPasswordBeforePreparingEncryptedMutation() async throws {
        let service = LockTestService()
        let store = try await connectedStore(service)
        let previous = try XCTUnwrap(store.items.first)
        var edited = previous
        edited.password = "replacement test password"
        await service.saveGate.pauseNext()
        let save = Task { await store.save(edited) }
        await service.saveGate.waitUntilSuspended()
        let prepared = await service.preparedItem
        XCTAssertEqual(prepared?.passwordHistory?.first?.password, previous.password)
        XCTAssertEqual(prepared?.passwordHistory?.first?.lastUsedDate, prepared?.updatedAt)
        XCTAssertEqual(prepared?.passwordUpdatedAt, prepared?.updatedAt)
        store.lock(requestAutomaticUnlock: false)
        await service.saveGate.resume()
        let saved = await save.value
        XCTAssertFalse(saved)
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
    var preparedItem: VaultItem?
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
        preparedItem = item
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
