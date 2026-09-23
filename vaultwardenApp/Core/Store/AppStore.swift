import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    private static let settingsStorageKey = "vaultwardenApp.settings"
    private let vaultwardenService: any VaultwardenService
    private let syncEngine: VaultSyncEngine
    private var retryTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var remoteCiphers: [UUID: RemoteCipherState] = [:]
    private var folderIDsByName: [String: String] = [:]
    private var remoteSends: [UUID: RemoteSendState] = [:]
    private var temporarySendPasswords: [UUID: String] = [:]
    private var organizationKeys: [String: String] = [:]
    private var backgroundedAt: Date?

    /// Sidebar selection. `nil` keeps the split view collapsed on the sidebar,
    /// which is the intended landing screen on iPhone.
    @Published var selectedFilter: VaultFilter?
    /// Detail-column selection.
    @Published var selectedItemID: UUID?
    @Published var items: [VaultItem] = []
    @Published var folders: [VaultFolder] = []
    @Published var collections: [VaultCollection] = []
    @Published var sends: [SendItem] = []
    @Published var settings: AppSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(settings) else { return }
            UserDefaults.standard.set(data, forKey: Self.settingsStorageKey)
            AutoFillSharedVault.setDefaultURIMatchType(
                settings.defaultURIMatchDetection ?? .baseDomain
            )
            AutoFillSharedVault.setShowsWebsiteIcons(settings.showFavicons)
        }
    }
    @Published var isLocked = false
    @Published var isSyncing = false
    @Published var lastSync = Date()
    @Published private(set) var authenticatedSession: AuthenticatedSession?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastUnlockError: String?
    @Published private(set) var lastSyncUsedOfflineCache = false
    @Published private(set) var discoveredServerVersion: String?
    @Published var userFacingNotice: String?
    @Published private(set) var pendingMutationCount = 0
    @Published private(set) var unlockPromptGeneration = 0
    @Published private(set) var shouldAutomaticallyPromptUnlock = true

    init(vaultwardenService: any VaultwardenService = DefaultVaultwardenService()) {
        self.vaultwardenService = vaultwardenService
        syncEngine = VaultSyncEngine(service: vaultwardenService)
        if let data = UserDefaults.standard.data(forKey: Self.settingsStorageKey),
           let savedSettings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = savedSettings
        } else {
            settings = AppSettings()
        }
        AutoFillSharedVault.setDefaultURIMatchType(
            settings.defaultURIMatchDetection ?? .baseDomain
        )
        AutoFillSharedVault.setShowsWebsiteIcons(settings.showFavicons)
        if let reference = settings.sessionReference,
           let serverURL = URL(string: settings.serverURL) {
            authenticatedSession = AuthenticatedSession(
                accountID: settings.email.lowercased(),
                serverURL: serverURL,
                tokenReference: reference
            )
            clearVisibleVault()
            isLocked = true
        }
        startAutomaticRetry()
    }

    var activeItems: [VaultItem] { items.filter { !$0.isDeleted && !$0.isArchived } }
    var unfolderedItems: [VaultItem] {
        activeItems.filter { item in
            item.folder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
    }
    var organizations: [String] {
        Array(Set(activeItems.compactMap(\.organization))).sorted()
    }
    var isAuthenticated: Bool { authenticatedSession != nil }

    func temporaryPassword(for sendID: UUID) -> String? {
        temporarySendPasswords[sendID]
    }

    func items(in category: VaultCategory) -> [VaultItem] {
        switch category {
        case .logins: activeItems.filter { $0.type == .login }
        case .passkeys: activeItems.filter { $0.passkeyCount > 0 }
        case .codes: activeItems.filter { $0.totpSecret?.isEmpty == false }
        case .cards: activeItems.filter { $0.type == .card }
        case .identities: activeItems.filter { $0.type == .identity }
        case .sshKeys: activeItems.filter { $0.type == .sshKey }
        case .secureNotes: activeItems.filter { $0.type == .secureNote }
        case .security: activeItems.filter { !$0.risks.isEmpty }
        case .archived: items.filter { $0.isArchived && !$0.isDeleted }
        case .deleted: items.filter(\.isDeleted)
        }
    }

    var favoriteItems: [VaultItem] { activeItems.filter(\.isFavorite) }

    /// Resolves a navigation selection into live items. Everything is derived
    /// from `items` on demand, so a list stays correct after an edit or sync
    /// without having to be re-entered.
    func items(for filter: VaultFilter) -> [VaultItem] {
        switch filter {
        case .all: activeItems
        case let .category(category): items(in: category)
        case .favorites: favoriteItems
        case .unfoldered: unfolderedItems
        case let .folder(name): items(inFolder: name)
        case let .collection(identifier): activeItems.filter { $0.collectionIDs.contains(identifier) }
        case let .organization(name): items(inOrganization: name)
        }
    }

    func count(for filter: VaultFilter) -> Int { items(for: filter).count }

    func title(for filter: VaultFilter) -> String {
        switch filter {
        case .all: L10n.string("All")
        case let .category(category): category.localizedTitle
        case .favorites: L10n.string("Favorites")
        case .unfoldered: L10n.string("Unfoldered")
        case let .folder(name): name
        case let .collection(identifier): collection(withID: identifier)?.name ?? L10n.string("Collection")
        case let .organization(name): name
        }
    }

    /// Shared vaults are modelled as collections when the server exposes them
    /// and fall back to plain organization names otherwise.
    var sharedFilters: [VaultFilter] {
        collections.isEmpty
            ? organizations.map(VaultFilter.organization)
            : collections.map { VaultFilter.collection($0.id) }
    }

    func items(inFolder folder: String) -> [VaultItem] {
        activeItems.filter { $0.folder == folder }
    }

    func items(inOrganization organization: String) -> [VaultItem] {
        activeItems.filter { $0.organization == organization }
    }

    func collection(withID identifier: String) -> VaultCollection? {
        collections.first { $0.id == identifier }
    }

    func search(_ query: String) -> [VaultItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return activeItems }
        return activeItems.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || $0.websiteURIs.contains { $0.localizedCaseInsensitiveContains(query) }
                || ($0.folder?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    @discardableResult
    func save(_ item: VaultItem) async -> Bool {
        guard let session = authenticatedSession else { return false }
        if let existing = remoteCiphers[item.id], !existing.canEdit {
            userFacingNotice = "This organization item is read-only and cannot be edited."
            return false
        }
        do {
            var updated = item
            updated.updatedAt = Date()
            if updated.createdAt == nil { updated.createdAt = updated.updatedAt }
            let mutation = try await vaultwardenService.prepareSaveCipher(
                item: updated,
                existing: remoteCiphers[item.id],
                folderID: item.folder.flatMap { folderIDsByName[$0] },
                organizationKeys: organizationKeys,
                session: session
            )
            return await enqueueAndAttempt(mutation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted update: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func trash(_ item: VaultItem) async -> Bool {
        guard let session = authenticatedSession else { return false }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.deletedAt = Date()
            return await save(updated)
        } else {
            return await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .trash, session: session)
            )
        }
    }

    func restore(_ item: VaultItem) async {
        guard let session = authenticatedSession else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.deletedAt = nil
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .restore, session: session)
            )
        }
    }

    func archive(_ item: VaultItem) async {
        guard let session = authenticatedSession, !item.isDeleted else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.archivedAt = Date()
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .archive, session: session)
            )
        }
    }

    func unarchive(_ item: VaultItem) async {
        guard let session = authenticatedSession else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.archivedAt = nil
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .unarchive, session: session)
            )
        }
    }

    @discardableResult
    func permanentlyDelete(_ item: VaultItem) async -> Bool {
        guard let session = authenticatedSession else { return false }
        return await enqueueAndAttempt(
            vaultwardenService.prepareCipherAction(id: item.id, action: .delete, session: session)
        )
    }

    func toggleFavorite(_ item: VaultItem) async {
        var updated = item
        updated.isFavorite.toggle()
        _ = await save(updated)
    }

    @discardableResult
    func addFolder(named name: String) async -> Bool {
        guard !name.isEmpty, !folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        guard let session = authenticatedSession else { return false }
        do {
            let folder = VaultFolder(name: name)
            let mutation = try await vaultwardenService.prepareFolderWrite(
                folder: folder,
                previousName: nil,
                serverID: nil,
                organizationKeys: organizationKeys,
                session: session
            )
            return await enqueueAndAttempt(mutation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted folder: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func renameFolder(_ folder: VaultFolder, to rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !folders.contains(where: { $0.id != folder.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        guard let session = authenticatedSession else { return false }
        do {
            var updated = folder
            updated.name = name
            let mutation = try await vaultwardenService.prepareFolderWrite(
                folder: updated,
                previousName: folder.name,
                serverID: folderIDsByName[folder.name],
                organizationKeys: organizationKeys,
                session: session
            )
            return await enqueueAndAttempt(mutation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted folder update: \(error.localizedDescription)"
            return false
        }
    }

    func deleteFolder(_ folder: VaultFolder) async {
        guard let session = authenticatedSession else { return }
        _ = await enqueueAndAttempt(
            vaultwardenService.prepareFolderDelete(
                folder: folder,
                serverID: folderIDsByName[folder.name],
                session: session
            )
        )
    }

    @discardableResult
    func addSend(_ send: SendItem, password: String? = nil, fileURL: URL? = nil) async -> Bool {
        guard let session = authenticatedSession else { return false }
        if send.kind == .file {
            guard let fileURL else {
                userFacingNotice = "Choose a file before creating this Send."
                return false
            }
            isSyncing = true
            defer { isSyncing = false }
            do {
                let createdSendID = try await vaultwardenService.createFileSend(
                    item: send,
                    password: password,
                    fileURL: fileURL,
                    session: session
                )
                let snapshot = try await vaultwardenService.sync(session: session)
                apply(snapshot)
                if let password, !password.isEmpty,
                   let createdSend = sends.first(where: { $0.id == createdSendID }),
                   let createdRemote = remoteSends[createdSendID] {
                    // Re-apply protection through the normal update endpoint after the
                    // file/v2 flow has assigned the final server Send ID.
                    let passwordMutation = try await vaultwardenService.prepareSendWrite(
                        item: createdSend,
                        password: nil,
                        passwordUpdate: .set(password),
                        existing: createdRemote,
                        session: session
                    )
                    guard await enqueueAndAttempt(passwordMutation) else { return false }
                    temporarySendPasswords[createdSendID] = password
                }
                return true
            } catch {
                userFacingNotice = "File Send failed: \(error.localizedDescription)"
                SecureLog.failure("File Send upload", error: error, logger: SecureLog.send)
                return false
            }
        }
        do {
            let sendIDsBeforeCreate = Set(remoteSends.keys)
            let mutation = try await vaultwardenService.prepareSendWrite(
                item: send,
                password: password,
                passwordUpdate: password.map(SendPasswordUpdate.set) ?? .preserve,
                existing: nil,
                session: session
            )
            guard await enqueueAndAttempt(mutation) else { return false }
            if let password, !password.isEmpty,
               let createdSend = sends.first(where: {
                   !sendIDsBeforeCreate.contains($0.id)
                       && $0.name == send.name
                       && $0.kind == send.kind
                       && abs($0.deletesAt.timeIntervalSince(send.deletesAt)) < 2
               }),
               let createdRemote = remoteSends[createdSend.id] {
                let passwordMutation = try await vaultwardenService.prepareSendWrite(
                    item: createdSend,
                    password: nil,
                    passwordUpdate: .set(password),
                    existing: createdRemote,
                    session: session
                )
                guard await enqueueAndAttempt(passwordMutation) else { return false }
                temporarySendPasswords[createdSend.id] = password
            }
            return true
        } catch {
            userFacingNotice = "Could not prepare the encrypted Send: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func updateSend(_ send: SendItem, passwordUpdate: SendPasswordUpdate = .preserve) async -> Bool {
        guard let session = authenticatedSession else { return false }
        do {
            let mutation = try await vaultwardenService.prepareSendWrite(
                item: send,
                password: nil,
                passwordUpdate: passwordUpdate,
                existing: remoteSends[send.id],
                session: session
            )
            var mutations = [mutation]
            if passwordUpdate == .remove {
                mutations.append(vaultwardenService.prepareSendPasswordRemoval(item: send, session: session))
            }
            let didSave = await enqueueAndAttempt(mutations)
            guard didSave else { return false }
            switch passwordUpdate {
            case let .set(password):
                temporarySendPasswords[send.id] = password
            case .remove:
                temporarySendPasswords[send.id] = nil
            case .preserve:
                break
            }
            return true
        } catch {
            userFacingNotice = "Could not prepare the encrypted Send update: \(error.localizedDescription)"
            return false
        }
    }

    func deleteSend(_ send: SendItem) async {
        guard let session = authenticatedSession else { return }
        _ = await enqueueAndAttempt(vaultwardenService.prepareSendDelete(id: send.id, session: session))
    }

    func downloadSendFile(_ send: SendItem, password: String?) async -> URL? {
        guard let session = authenticatedSession,
              let remote = remoteSends[send.id] else {
            userFacingNotice = "Sync this Send before downloading its file."
            return nil
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let url = try await vaultwardenService.downloadAndDecryptSendFile(
                item: send,
                remote: remote,
                password: password,
                session: session
            )
            return url
        } catch {
            userFacingNotice = "Download failed: \(error.localizedDescription)"
            SecureLog.failure("File Send download", error: error, logger: SecureLog.send)
            return nil
        }
    }

    func connect(
        serverURL: String,
        email: String,
        masterPassword: String,
        twoFactorCode: String? = nil
    ) async throws {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VaultwardenServiceError.invalidServerURL
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let session = try await vaultwardenService.login(
            serverURL: url,
            email: normalizedEmail,
            masterPassword: masterPassword,
            twoFactorCode: twoFactorCode
        )
        isSyncing = true
        defer { isSyncing = false }
        let snapshot: EncryptedVaultSnapshot
        do {
            snapshot = try await vaultwardenService.sync(session: session)
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }

        settings.serverURL = session.serverURL.absoluteString
        settings.email = normalizedEmail
        settings.sessionReference = session.tokenReference
        authenticatedSession = session
        apply(snapshot)
        await updatePendingMutationCount()
        isLocked = false
        backgroundedAt = nil
        lastUnlockError = nil
    }

    func testConnection(serverURL: String) async throws -> ServerConfiguration {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VaultwardenServiceError.invalidServerURL
        }
        let configuration = try await vaultwardenService.discover(serverURL: url)
        discoveredServerVersion = configuration.version
        return configuration
    }

    func loadPendingLoginRequests() async throws -> [PendingLoginRequest] {
        guard let authenticatedSession else {
            throw VaultwardenServiceError.sessionExpired
        }
        return try await vaultwardenService.pendingLoginRequests(session: authenticatedSession)
    }

    func respondToLoginRequest(_ request: PendingLoginRequest, approved: Bool) async throws {
        guard let authenticatedSession else {
            throw VaultwardenServiceError.sessionExpired
        }
        try await vaultwardenService.respondToLoginRequest(
            request,
            approved: approved,
            session: authenticatedSession
        )
    }

    func sync() async {
        guard !isSyncing else { return }
        guard let authenticatedSession else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try? await syncEngine.retryBlocked(reference: authenticatedSession.tokenReference)
            let flush = await syncEngine.flush(session: authenticatedSession)
            let snapshot = try await vaultwardenService.sync(session: authenticatedSession)
            apply(snapshot)
            await applyPendingProjectionsAndPublish()
            await updatePendingMutationCount()
            userFacingNotice = flush.problemNotice
            lastSyncError = nil
            SecureLog.event("Vault sync completed", logger: SecureLog.sync)
        } catch is CancellationError {
            // A caller can intentionally cancel a sync (for example when its view disappears).
            // Cancellation is not a server failure and must not replace a successful last-sync state.
            SecureLog.event("Vault sync cancelled by caller", logger: SecureLog.sync)
        } catch {
            lastSyncError = error.localizedDescription
            userFacingNotice = "Sync failed: \(error.localizedDescription)"
            SecureLog.failure("Vault sync", error: error, logger: SecureLog.sync)
        }
    }

    /// Runs pull-to-refresh independently from SwiftUI's short-lived refresh task.
    /// An unstructured task doesn't inherit later cancellation when the gesture/view lifecycle ends.
    func syncFromPullToRefresh() async {
        let syncTask = Task { @MainActor in
            await sync()
        }
        await syncTask.value
    }

    func exportEncryptedVault(password: String) async throws -> URL {
        guard authenticatedSession != nil else { throw VaultArchiveError.signedOut }
        guard !isLocked else { throw VaultArchiveError.vaultLocked }
        let personalItems = items.filter { !$0.isDeleted && $0.organization == nil }
        let payload = VaultArchivePayload(
            version: VaultArchivePayload.currentVersion,
            exportedAt: Date(),
            items: personalItems.map { item in
                var copy = item
                // Passkey private material is managed by the Bitwarden SDK and is never represented by this UI model.
                copy.passkeyCount = 0
                return copy
            },
            folders: folders,
            excludedOrganizationItems: items.filter { $0.organization != nil }.count,
            excludedPasskeys: personalItems.reduce(0) { $0 + $1.passkeyCount }
        )
        let archive = try await Task.detached(priority: .userInitiated) {
            try EncryptedVaultArchive.seal(payload, password: password)
        }.value
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vaultwarden-\(formatter.string(from: Date())).vwvault")
        try archive.write(to: url, options: ClientPlatform.protectedFileWritingOptions)
        return url
    }

    func importEncryptedVault(data: Data, password: String) async throws -> VaultArchiveImportSummary {
        guard authenticatedSession != nil else { throw VaultArchiveError.signedOut }
        guard !isLocked else { throw VaultArchiveError.vaultLocked }
        let payload = try await Task.detached(priority: .userInitiated) {
            try EncryptedVaultArchive.open(data, password: password)
        }.value

        var importedFolders = 0
        for folder in payload.folders where !folders.contains(where: {
            $0.name.caseInsensitiveCompare(folder.name) == .orderedSame
        }) {
            if await addFolder(named: folder.name) { importedFolders += 1 }
        }

        var importedItems = 0
        var failedItems = 0
        for archivedItem in payload.items {
            var item = archivedItem
            item.id = UUID()
            item.organization = nil
            item.collectionIDs = []
            item.deletedAt = nil
            item.archivedAt = nil
            item.createdAt = Date()
            item.passkeyCount = 0
            item.updatedAt = Date()
            if await save(item) { importedItems += 1 } else { failedItems += 1 }
        }
        return VaultArchiveImportSummary(
            importedItems: importedItems,
            importedFolders: importedFolders,
            failedItems: failedItems
        )
    }

    private func apply(_ snapshot: EncryptedVaultSnapshot) {
        items = VaultSecurityAnalyzer.analyze(snapshot.decrypted.items)
        folders = snapshot.decrypted.folders
        collections = snapshot.decrypted.collections
        sends = snapshot.decrypted.sends
        remoteCiphers = snapshot.decrypted.remoteCiphers
        folderIDsByName = snapshot.decrypted.folderIDsByName
        remoteSends = snapshot.decrypted.remoteSends
        organizationKeys = snapshot.decrypted.organizationKeys
        lastSync = snapshot.revision
        lastSyncError = nil
        lastSyncUsedOfflineCache = snapshot.isFromOfflineCache
        discardSelectionForMissingItem()
    }

    private func apply(_ projection: VaultMutationProjection) {
        var state = VaultProjectionState(items: items, folders: folders, sends: sends)
        VaultProjectionReducer.apply(projection, to: &state)
        items = VaultSecurityAnalyzer.analyze(state.items)
        folders = state.folders
        sends = state.sends
        switch projection {
        case let .deleteItem(id): remoteCiphers[id] = nil
        case let .deleteSend(id): remoteSends[id] = nil
        default: break
        }
        discardSelectionForMissingItem()
    }

    /// Keeps the split view's detail column from stranding on an item that a
    /// sync or a permanent delete has just removed.
    private func discardSelectionForMissingItem() {
        guard let selectedItemID else { return }
        if !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
        }
    }

    private func clearVisibleVault() {
        items = []
        folders = []
        collections = []
        sends = []
        remoteCiphers = [:]
        folderIDsByName = [:]
        remoteSends = [:]
        temporarySendPasswords = [:]
        organizationKeys = [:]
    }

    private func enqueueAndAttempt(_ mutation: PreparedVaultMutation) async -> Bool {
        await enqueueAndAttempt([mutation])
    }

    private func enqueueAndAttempt(_ mutations: [PreparedVaultMutation]) async -> Bool {
        do {
            for mutation in mutations {
                try await syncEngine.enqueue(mutation)
                apply(mutation.projection)
            }
            await publishLocalAutoFillIndex()
            await updatePendingMutationCount()
            await flushPendingMutations(refreshVault: true, showDeferredNotice: true)
            return true // Safely queued is a successful local save, even when offline.
        } catch {
            userFacingNotice = "The encrypted offline change could not be saved: \(error.localizedDescription)"
            SecureLog.failure("Mutation queue write", error: error, logger: SecureLog.sync)
            return false
        }
    }

    private func flushPendingMutations(refreshVault: Bool, showDeferredNotice: Bool) async {
        guard let session = authenticatedSession else { return }
        let mutationsBeforeFlush = (try? await syncEngine.mutations(reference: session.tokenReference)) ?? []
        let queuedBeforeFlush = (try? await syncEngine.pendingCount(reference: session.tokenReference)) ?? 0
        if refreshVault, queuedBeforeFlush > 0 { isSyncing = true }
        defer {
            if refreshVault, queuedBeforeFlush > 0 { isSyncing = false }
        }
        let result = await syncEngine.flush(session: session)
        await updatePendingMutationCount()
        if (result.madeServerChanges || result.removedTerminalMutations > 0), refreshVault, !isLocked {
            do {
                let snapshot = try await vaultwardenService.sync(session: session)
                apply(snapshot)
                // A successful write can be followed by an eventually-consistent
                // `/sync` response that still contains the previous item state.
                // Keep completed non-create projections through this first refresh
                // so rows do not disappear and immediately reappear.
                let completedIDs = Set(result.completedMutationIDs)
                for mutation in mutationsBeforeFlush
                where completedIDs.contains(mutation.id) && !mutation.isCreate {
                    apply(mutation.projection)
                }
                await applyPendingProjectionsAndPublish()
            } catch {
                // Server writes are already committed. Keep the optimistic projection until retry sync succeeds.
                lastSyncError = error.localizedDescription
            }
        }
        if showDeferredNotice, result.deferred > 0 {
            userFacingNotice = "Saved securely offline. Vaultwarden will retry automatically when the server is reachable."
        } else if let problemNotice = result.problemNotice {
            userFacingNotice = problemNotice
        } else if result.madeServerChanges {
            userFacingNotice = nil
        }
    }

    private func applyPendingProjectionsAndPublish() async {
        guard let reference = authenticatedSession?.tokenReference,
              let mutations = try? await syncEngine.mutations(reference: reference) else { return }
        for mutation in mutations.sorted(by: { $0.createdAt < $1.createdAt }) {
            apply(mutation.projection)
        }
        if !mutations.isEmpty { await publishLocalAutoFillIndex() }
    }

    private func publishLocalAutoFillIndex() async {
        guard let session = authenticatedSession else { return }
        let snapshot = DecryptedVaultSnapshot(
            items: items,
            folders: folders,
            collections: collections,
            sends: sends,
            remoteCiphers: remoteCiphers,
            folderIDsByName: folderIDsByName,
            remoteSends: remoteSends,
            organizationKeys: organizationKeys
        )
        await vaultwardenService.publishAutoFillIndex(snapshot: snapshot, session: session)
    }

    private func updatePendingMutationCount() async {
        guard let reference = authenticatedSession?.tokenReference else {
            pendingMutationCount = 0
            return
        }
        pendingMutationCount = (try? await syncEngine.pendingCount(reference: reference)) ?? 0
    }

    private func startAutomaticRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.authenticatedSession != nil else { continue }
                await self.flushPendingMutations(refreshVault: !self.isLocked, showDeferredNotice: false)
            }
        }
    }

    func performBackgroundRefresh() async -> Bool {
        guard settings.backgroundRefresh, let session = authenticatedSession else { return true }
        let result = await syncEngine.flush(session: session)
        do {
            try await vaultwardenService.refreshEncryptedCache(session: session)
            await updatePendingMutationCount()
            return !result.hasProblems
        } catch {
            SecureLog.failure("Background refresh", error: error, logger: SecureLog.background)
            return false
        }
    }

    func clearEncryptedLocalCache() async throws {
        guard let session = authenticatedSession else { throw VaultArchiveError.signedOut }
        try await vaultwardenService.clearEncryptedCache(session: session)
        userFacingNotice = "The encrypted offline cache was cleared. Server data and queued changes were not deleted."
    }

    func appDidEnterBackground(at date: Date = Date()) {
        guard authenticatedSession != nil else { return }
        backgroundedAt = date
        // A manual Lock Now intentionally waits for the Unlock button. Do not
        // turn it back into an automatic prompt when the app is backgrounded.
        if !isLocked, settings.vaultTimeout == .immediately {
            lock()
        }
    }

    func refreshAfterBecomingActive(at date: Date = Date()) async {
        guard authenticatedSession != nil else { return }
        if !isLocked,
           let backgroundedAt,
           let timeout = settings.vaultTimeout.timeInterval,
           date.timeIntervalSince(backgroundedAt) >= timeout {
            lock()
        }
        backgroundedAt = nil
        await flushPendingMutations(refreshVault: !isLocked, showDeferredNotice: false)
    }

    func lock(requestAutomaticUnlock: Bool = true) {
        shouldAutomaticallyPromptUnlock = requestAutomaticUnlock
        if requestAutomaticUnlock { unlockPromptGeneration &+= 1 }
        temporarySendPasswords = [:]
        isLocked = true
        let session = authenticatedSession
        let previousLockTask = lockTask
        lockTask = Task { [vaultwardenService] in
            if let previousLockTask { await previousLockTask.value }
            await vaultwardenService.lock(session: session)
        }
    }

    func logoutAndDeleteLocalData() async {
        guard let session = authenticatedSession else { return }
        if let lockTask { await lockTask.value }
        lockTask = nil
        var cleanupFailure: Error?
        do {
            try await vaultwardenService.logout(session: session)
        } catch {
            cleanupFailure = error
        }
        do {
            try await syncEngine.clear(reference: session.tokenReference)
        } catch {
            cleanupFailure = cleanupFailure ?? error
        }
        do {
            try LocalAccountDataPurger.purgeKeychainItems()
        } catch {
            cleanupFailure = cleanupFailure ?? error
        }

        removeLocalAccountArtifacts()
        BackgroundSyncManager.cancelPendingRefresh()
        settings = AppSettings()
        UserDefaults.standard.removeObject(forKey: Self.settingsStorageKey)
        UserDefaults.standard.removeObject(forKey: "vaultwardenApp.deviceIdentifier")

        authenticatedSession = nil
        clearVisibleVault()
        backgroundedAt = nil
        isLocked = false
        isSyncing = false
        lastSync = Date()
        lastSyncError = nil
        lastUnlockError = nil
        lastSyncUsedOfflineCache = false
        discoveredServerVersion = nil
        pendingMutationCount = 0
        selectedFilter = nil
        selectedItemID = nil

        if cleanupFailure != nil {
            userFacingNotice = "You were logged out, but the system could not verify removal of every protected Keychain item. Restart the device and log out again before handing it to someone else."
            SecureLog.event("Logout completed with a protected-storage cleanup failure", logger: SecureLog.security)
        }
    }

    private func removeLocalAccountArtifacts() {
        let fileManager = FileManager.default
        try? AutoFillSharedVault.clear()
        if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            for directory in ["EncryptedVaultCache", "MutationQueue"] {
                try? fileManager.removeItem(at: applicationSupport.appendingPathComponent(directory, isDirectory: true))
            }
        }
        if let caches = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            try? fileManager.removeItem(at: caches.appendingPathComponent("WebsiteIcons", isDirectory: true))
        }
        try? fileManager.removeItem(at: AutoFillSharedVault.websiteIconCacheDirectory)

        let temporaryRoot = fileManager.temporaryDirectory
        for directory in ["EncryptedSendUploads", "DecryptedSends"] {
            try? fileManager.removeItem(at: temporaryRoot.appendingPathComponent(directory, isDirectory: true))
        }
        if let temporaryFiles = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil
        ) {
            for url in temporaryFiles where url.lastPathComponent.hasPrefix("Vaultwarden-")
                && url.pathExtension == "vwvault" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func unlockWithBiometrics() async -> Bool {
        guard UnlockPresentationPolicy.isAllowed, !Task.isCancelled else { return false }
        do {
            if let lockTask { await lockTask.value }
            lockTask = nil
            // Focus may have changed while the preceding lock finished.
            guard UnlockPresentationPolicy.isAllowed, !Task.isCancelled else { return false }
            if let authenticatedSession {
                try await vaultwardenService.unlock(session: authenticatedSession)
            } else {
                let success = await BiometricAuthenticator.authenticate(
                    reason: "Unlock your vault",
                    allowPasscode: settings.devicePasscodeFallback
                )
                guard success else { return false }
            }
            lastUnlockError = nil
            isLocked = false
            backgroundedAt = nil
            if items.isEmpty {
                await restoreCachedVaultIfAvailable()
            }
            if items.isEmpty || settings.syncOnOpen {
                Task { await sync() }
            } else {
                Task { await flushPendingMutations(refreshVault: true, showDeferredNotice: false) }
            }
            return true
        } catch {
            lastUnlockError = error.localizedDescription
            return false
        }
    }

    func unlock(masterPassword: String) async -> Bool {
        guard !masterPassword.isEmpty else { return false }
        do {
            if let lockTask { await lockTask.value }
            lockTask = nil
            if let authenticatedSession {
                try await vaultwardenService.unlock(
                    session: authenticatedSession,
                    masterPassword: masterPassword
                )
            }
            lastUnlockError = nil
            isLocked = false
            backgroundedAt = nil
            if items.isEmpty {
                await restoreCachedVaultIfAvailable()
            }
            if items.isEmpty || settings.syncOnOpen {
                Task { await sync() }
            } else {
                Task { await flushPendingMutations(refreshVault: true, showDeferredNotice: false) }
            }
            return true
        } catch {
            lastUnlockError = error.localizedDescription
            return false
        }
    }

    private func restoreCachedVaultIfAvailable() async {
        guard let session = authenticatedSession else { return }
        do {
            let snapshot = try await vaultwardenService.loadCachedVault(session: session)
            apply(snapshot)
            await applyPendingProjectionsAndPublish()
            await updatePendingMutationCount()
            SecureLog.event("Encrypted offline vault restored", logger: SecureLog.sync)
        } catch {
            // A missing cache is expected on the first login. The normal sync path
            // below will download and seed it when the server is reachable.
        }
    }
}
