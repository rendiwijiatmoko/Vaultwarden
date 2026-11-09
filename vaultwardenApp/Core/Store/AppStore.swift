import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    private static let settingsStorageKey = "vaultwardenApp.settings"
    private let settingsDefaults: UserDefaults
    private let vaultwardenService: any VaultwardenService
    private let syncEngine: VaultSyncEngine
    private let loginApprovalAuthenticator: @MainActor @Sendable () async -> Bool
    private var retryTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var remoteCiphers: [UUID: RemoteCipherState] = [:]
    private var folderIDsByName: [String: String] = [:]
    private var remoteSends: [UUID: RemoteSendState] = [:]
    private var temporarySendPasswords: [UUID: String] = [:]
    private var organizationKeys: [String: String] = [:]
    // Invalidates results started before a lock, even if the vault unlocks again.
    private(set) var vaultGeneration: UInt64 = 0
    private var backgroundedAt: Date?
    private var settingsSaveTask: Task<Void, Never>?
    /// Derived item lists, rebuilt lazily after `items` changes. Sidebar counts and
    /// list filters read these many times per render; recomputing each was O(n) per call.
    private var derivedItemsStorage: DerivedVaultItems?
    private var derivedItems: DerivedVaultItems {
        if let derivedItemsStorage { return derivedItemsStorage }
        let derived = DerivedVaultItems(items: items)
        derivedItemsStorage = derived
        return derived
    }

    /// Sidebar selection. `nil` keeps the split view collapsed on the sidebar,
    /// which is the intended landing screen on iPhone.
    @Published var selectedFilter: VaultFilter?
    /// Detail-column selection.
    @Published var selectedItemID: UUID?
    @Published var items: [VaultItem] = [] {
        didSet { derivedItemsStorage = nil }
    }
    @Published var folders: [VaultFolder] = []
    @Published var collections: [VaultCollection] = []
    @Published var sends: [SendItem] = []
    @Published var settings: AppSettings {
        didSet {
            persistSettings(after: oldValue)
            let matchType = settings.defaultURIMatchDetection ?? .baseDomain
            if matchType != (oldValue.defaultURIMatchDetection ?? .baseDomain) {
                AutoFillSharedVault.setDefaultURIMatchType(matchType)
            }
            if settings.showFavicons != oldValue.showFavicons {
                AutoFillSharedVault.setShowsWebsiteIcons(settings.showFavicons)
            }
            if settings.haptics != oldValue.haptics {
                AutoFillSharedVault.setHapticsEnabled(settings.haptics)
            }
            Clipboard.clearsAutomatically = settings.clearClipboard
            Clipboard.playsHaptics = settings.haptics
            if settings.biometricUnlock != oldValue.biometricUnlock
                || settings.devicePasscodeFallback != oldValue.devicePasscodeFallback {
                configureDeviceUnlock()
                let generation = vaultGeneration
                Task {
                    guard let session = authenticatedSession else { return }
                    do {
                        try await vaultwardenService.refreshDeviceUnlock(session: session)
                        await publishLocalAutoFillIndex(generation: generation)
                    } catch {
                        userFacingNotice = "Device unlock could not be configured. Use your master password to unlock the vault."
                    }
                }
            }
        }
    }
    @Published var isLocked = false
    @Published var isSyncing = false
    @Published var lastSync = Date()
    /// When this device last finished a sync with the server, as opposed to `lastSync`, the vault's revision date.
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var authenticatedSession: AuthenticatedSession?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var sessionNeedsSignIn = false
    @Published private(set) var lastUnlockError: String?
    @Published private(set) var lastSyncUsedOfflineCache = false
    @Published private(set) var discoveredServerVersion: String?
    @Published var userFacingNotice: String?
    @Published private(set) var pendingMutationCount = 0
    @Published private(set) var unlockPromptGeneration = 0
    @Published private(set) var shouldAutomaticallyPromptUnlock = true

    // Releasing the store must not hop to the main actor. The implicit isolated
    // deinit aborts in the Swift runtime when a task-local scope is active.
    nonisolated deinit {}

    init(
        vaultwardenService: any VaultwardenService = DefaultVaultwardenService(),
        settingsDefaults: UserDefaults = .standard,
        loginApprovalAuthenticator: @escaping @MainActor @Sendable () async -> Bool = {
            await BiometricAuthenticator.authenticate(reason: "Approve access to your vault on another device", allowPasscode: false)
        }
    ) {
        self.settingsDefaults = settingsDefaults
        self.loginApprovalAuthenticator = loginApprovalAuthenticator
        self.vaultwardenService = vaultwardenService
        syncEngine = VaultSyncEngine(service: vaultwardenService)
        settings = Self.loadSettings(from: settingsDefaults)
        AutoFillSharedVault.setDefaultURIMatchType(
            settings.defaultURIMatchDetection ?? .baseDomain
        )
        AutoFillSharedVault.setShowsWebsiteIcons(settings.showFavicons)
        AutoFillSharedVault.setHapticsEnabled(settings.haptics)
        Clipboard.clearsAutomatically = settings.clearClipboard
        Clipboard.playsHaptics = settings.haptics
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
        configureDeviceUnlock()
        startAutomaticRetry()
        // Nothing can be mid-transfer at launch; sweep files a crash left behind.
        Task.detached(priority: .utility) { TemporaryVaultFiles.removeAll() }
    }

    /// Saved settings decode all-or-nothing. If one field can't be read (for
    /// example after a downgrade), keep the account and security choices instead
    /// of signing the person out and resetting everything.
    static func loadSettings(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: settingsStorageKey) else { return AppSettings() }
        if let saved = try? JSONDecoder().decode(AppSettings.self, from: data) { return saved }
        var recovered = AppSettings()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return recovered
        }
        if let value = object["serverURL"] as? String { recovered.serverURL = value }
        if let value = object["email"] as? String { recovered.email = value }
        if let value = object["sessionReference"] as? String { recovered.sessionReference = value }
        let flags: [(String, WritableKeyPath<AppSettings, Bool>)] = [
            ("biometricUnlock", \.biometricUnlock),
            ("requireBiometricForSensitiveActions", \.requireBiometricForSensitiveActions),
            ("devicePasscodeFallback", \.devicePasscodeFallback),
            ("clearClipboard", \.clearClipboard),
            ("showFavicons", \.showFavicons),
            ("haptics", \.haptics),
            ("autoSync", \.autoSync),
            ("syncOnOpen", \.syncOnOpen),
            ("backgroundRefresh", \.backgroundRefresh)
        ]
        for (key, keyPath) in flags {
            if let value = object[key] as? Bool { recovered[keyPath: keyPath] = value }
        }
        if let raw = object["vaultTimeout"] as? String, let value = VaultTimeout(rawValue: raw) {
            recovered.vaultTimeout = value
        }
        if let raw = object["theme"] as? String, let value = AppTheme(rawValue: raw) {
            recovered.theme = value
        }
        SecureLog.event("Saved settings partially recovered", logger: SecureLog.security)
        return recovered
    }

    /// Text fields bind straight to settings, so typing an email or server URL would
    /// otherwise JSON-encode and write UserDefaults on every keystroke. Those two
    /// fields are written shortly after typing pauses; everything else immediately.
    private func persistSettings(after oldValue: AppSettings) {
        let isTypingChange = settings.sessionReference == oldValue.sessionReference
            && (settings.email != oldValue.email || settings.serverURL != oldValue.serverURL)
        guard isTypingChange else {
            persistSettingsNow()
            return
        }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistSettingsNow()
        }
    }

    /// Writes settings synchronously. Call before the process may be suspended or quit.
    func persistSettingsNow() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        guard let data = try? JSONEncoder().encode(settings) else { return }
        settingsDefaults.set(data, forKey: Self.settingsStorageKey)
    }

    private func configureDeviceUnlock() {
        do {
            try DeviceUnlockPolicy.configure(DeviceUnlockPolicy(
                biometricsEnabled: settings.biometricUnlock,
                passcodeFallback: settings.devicePasscodeFallback
            ))
        } catch {
            userFacingNotice = "Device unlock was disabled because its protected keys could not be updated. Use your master password."
            SecureLog.failure("Device unlock configuration", error: error, logger: SecureLog.security)
        }
    }

    var sortedFolders: [VaultFolder] { settings.vaultSortOrder.sortedFolders(folders) }

    var activeItems: [VaultItem] { derivedItems.active }
    var unfolderedItems: [VaultItem] { derivedItems.unfoldered }
    var organizations: [String] { derivedItems.organizations }
    var isAuthenticated: Bool { authenticatedSession != nil }

    /// Server edit permission; items not yet synced are the user's own.
    func canEdit(_ item: VaultItem) -> Bool { remoteCiphers[item.id]?.canEdit ?? true }

    func temporaryPassword(for sendID: UUID) -> String? {
        temporarySendPasswords[sendID]
    }

    func items(in category: VaultCategory) -> [VaultItem] {
        derivedItems.items(in: category)
    }

    var favoriteItems: [VaultItem] { derivedItems.favorites }

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
        case let .collection(identifier): derivedItems.items(inCollection: identifier)
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
    var sharedCollectionGroups: [VaultCollectionGroup] {
        VaultCollectionGroup.grouped(collections: collections, organizations: organizations)
    }

    var sharedFilters: [VaultFilter] {
        sharedCollectionGroups.flatMap(\.filters)
    }

    func items(inFolder folder: String) -> [VaultItem] {
        derivedItems.items(inFolder: folder)
    }

    func items(inOrganization organization: String) -> [VaultItem] {
        derivedItems.items(inOrganization: organization)
    }

    func collection(withID identifier: String) -> VaultCollection? {
        collections.first { $0.id == identifier }
    }

    /// Organization keys require explicit permission metadata from the current session.
    func canUseSSHKey(_ item: VaultItem) -> Bool {
        guard item.type == .sshKey, !item.isDeleted, !item.isArchived, !item.password.isEmpty else { return false }
        if let remote = remoteCiphers[item.id] { return remote.canViewPassword }
        return item.organization == nil && item.collectionIDs.isEmpty
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

    /// Quick access must honor the same organization password restriction as SSH.
    func canCopyLoginPassword(_ item: VaultItem) -> Bool {
        item.type == .login && canCopyVaultSecrets(item)
    }

    func canCopyVaultSecrets(_ item: VaultItem) -> Bool {
        guard isAuthenticated, !isLocked,
              !item.isDeleted, !item.isArchived else { return false }
        if let remote = remoteCiphers[item.id] { return remote.canViewPassword }
        return item.organization == nil && item.collectionIDs.isEmpty
    }

    func quickCopyFields(for item: VaultItem, date: Date = Date()) -> [VaultQuickCopyField] {
        guard isAuthenticated, !isLocked, !item.isDeleted, !item.isArchived else { return [] }
        return VaultQuickCopyField.fields(for: item, date: date)
            .filter { !$0.isSensitive || canCopyVaultSecrets(item) }
    }

    @discardableResult
    func save(_ item: VaultItem) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
        guard let session = authenticatedSession else { return false }
        if let existing = remoteCiphers[item.id], !existing.canEdit {
            userFacingNotice = "This organization item is read-only and cannot be edited."
            return false
        }
        do {
            var updated = item
            updated.updatedAt = Date()
            if updated.createdAt == nil { updated.createdAt = updated.updatedAt }
            if let previous = items.first(where: { $0.id == item.id }),
               remoteCiphers[item.id]?.canViewPassword != false {
                updated.recordPasswordChange(from: previous, at: updated.updatedAt)
            } else if items.allSatisfy({ $0.id != item.id }), updated.type == .login, !updated.password.isEmpty {
                updated.passwordUpdatedAt = updated.passwordUpdatedAt ?? updated.updatedAt
            }
            let mutation = try await vaultwardenService.prepareSaveCipher(
                item: updated,
                existing: remoteCiphers[item.id],
                folderID: item.folder.flatMap { folderIDsByName[$0] },
                organizationKeys: organizationKeys,
                session: session
            )
            return await enqueueAndAttempt(mutation, generation: generation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted update: \(error.localizedDescription)"
            return false
        }
    }

    func addAttachment(to itemID: UUID, fileURL: URL, fileName: String) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
        guard let session = authenticatedSession else { return false }
        guard pendingMutationCount == 0 else {
            userFacingNotice = "Sync pending vault changes before uploading an attachment."
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if remoteCiphers[itemID] == nil {
                let snapshot = try await vaultwardenService.sync(session: session)
                guard apply(snapshot, generation: generation) else { return false }
            }
            guard let cipher = remoteCiphers[itemID], cipher.canEdit else {
                userFacingNotice = "Save and sync this item before adding an attachment."
                return false
            }
            try await vaultwardenService.uploadAttachment(
                fileURL: fileURL, fileName: fileName,
                cipher: cipher, organizationKeys: organizationKeys, session: session
            )
            let snapshot = try await vaultwardenService.sync(session: session)
            guard apply(snapshot, generation: generation) else { return false }
            await applyPendingProjectionsAndPublish(generation: generation)
            return true
        } catch {
            userFacingNotice = "Attachment upload failed: \(error.localizedDescription)"
            SecureLog.failure("Attachment upload", error: error, logger: SecureLog.sync)
            return false
        }
    }

    func removeAttachment(_ attachment: VaultAttachment, from itemID: UUID) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
        guard let session = authenticatedSession else { return false }
        guard pendingMutationCount == 0 else {
            userFacingNotice = "Sync pending vault changes before removing an attachment."
            return false
        }
        guard let cipher = remoteCiphers[itemID], cipher.canEdit else {
            userFacingNotice = "This item cannot be edited right now."
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await vaultwardenService.deleteAttachment(
                attachmentID: attachment.id, cipher: cipher, session: session
            )
        } catch {
            userFacingNotice = "Attachment removal failed: \(error.localizedDescription)"
            SecureLog.failure("Attachment removal", error: error, logger: SecureLog.sync)
            return false
        }

        // The server deletion has succeeded. Keep the row and paperclip accurate
        // even if the subsequent vault refresh is delayed or unavailable.
        do {
            let snapshot = try await vaultwardenService.sync(session: session)
            guard apply(snapshot, generation: generation) else { return false }
        } catch {
            lastSyncError = error.localizedDescription
            SecureLog.failure("Attachment refresh", error: error, logger: SecureLog.sync)
        }
        guard acceptsVaultResult(generation) else { return false }
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].attachments?.removeAll { $0.id == attachment.id }
        }
        return true
    }

    func downloadAttachment(_ attachment: VaultAttachment, from itemID: UUID) async -> URL? {
        let generation = vaultGeneration
        guard !isLocked else { return nil }
        guard let session = authenticatedSession,
              let cipher = remoteCiphers[itemID] else {
            userFacingNotice = "Sync this item before downloading its attachment."
            return nil
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let url = try await vaultwardenService.downloadAttachment(
                attachment: attachment, cipher: cipher,
                organizationKeys: organizationKeys, session: session
            )
            return keepDecryptedFile(url, generation: generation)
        } catch is CancellationError {
            return nil
        } catch {
            userFacingNotice = "Attachment download failed: \(error.localizedDescription)"
            SecureLog.failure("Attachment download", error: error, logger: SecureLog.sync)
            return nil
        }
    }

    @discardableResult
    func trash(_ item: VaultItem) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
        guard let session = authenticatedSession else { return false }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.deletedAt = Date()
            return await save(updated)
        } else {
            return await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .trash, session: session),
                generation: generation
            )
        }
    }

    func restore(_ item: VaultItem) async {
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard let session = authenticatedSession else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.deletedAt = nil
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .restore, session: session),
                generation: generation
            )
        }
    }

    func archive(_ item: VaultItem) async {
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard let session = authenticatedSession, !item.isDeleted else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.archivedAt = Date()
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .archive, session: session),
                generation: generation
            )
        }
    }

    func unarchive(_ item: VaultItem) async {
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard let session = authenticatedSession else { return }
        if remoteCiphers[item.id] == nil {
            var updated = item
            updated.archivedAt = nil
            _ = await save(updated)
        } else {
            _ = await enqueueAndAttempt(
                vaultwardenService.prepareCipherAction(id: item.id, action: .unarchive, session: session),
                generation: generation
            )
        }
    }

    @discardableResult
    func permanentlyDelete(_ item: VaultItem) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
        guard let session = authenticatedSession else { return false }
        return await enqueueAndAttempt(
            vaultwardenService.prepareCipherAction(id: item.id, action: .delete, session: session),
            generation: generation
        )
    }

    func toggleFavorite(_ item: VaultItem) async {
        var updated = item
        updated.isFavorite.toggle()
        _ = await save(updated)
    }

    @discardableResult
    func addFolder(named name: String) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
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
            return await enqueueAndAttempt(mutation, generation: generation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted folder: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func renameFolder(_ folder: VaultFolder, to rawName: String) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
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
            return await enqueueAndAttempt(mutation, generation: generation)
        } catch {
            userFacingNotice = "Could not prepare the encrypted folder update: \(error.localizedDescription)"
            return false
        }
    }

    func deleteFolder(_ folder: VaultFolder) async {
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard let session = authenticatedSession else { return }
        _ = await enqueueAndAttempt(
            vaultwardenService.prepareFolderDelete(
                folder: folder,
                serverID: folderIDsByName[folder.name],
                session: session
            ),
            generation: generation
        )
    }

    @discardableResult
    func addSend(_ send: SendItem, password: String? = nil, fileURL: URL? = nil) async -> Bool {
        let generation = vaultGeneration
        guard !isLocked else { return false }
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
                guard apply(snapshot, generation: generation) else { return false }
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
                    guard await enqueueAndAttempt(passwordMutation, generation: generation),
                          acceptsVaultResult(generation) else { return false }
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
            guard await enqueueAndAttempt(mutation, generation: generation) else { return false }
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
                guard await enqueueAndAttempt(passwordMutation, generation: generation),
                          acceptsVaultResult(generation) else { return false }
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
        let generation = vaultGeneration
        guard !isLocked else { return false }
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
            let didSave = await enqueueAndAttempt(mutations, generation: generation)
            guard didSave, acceptsVaultResult(generation) else { return false }
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
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard let session = authenticatedSession else { return }
        _ = await enqueueAndAttempt(vaultwardenService.prepareSendDelete(id: send.id, session: session), generation: generation)
    }

    func downloadSendFile(_ send: SendItem, password: String?) async -> URL? {
        let generation = vaultGeneration
        guard !isLocked else { return nil }
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
            return keepDecryptedFile(url, generation: generation)
        } catch is CancellationError {
            return nil
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
        let generation = vaultGeneration
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

        guard generation == vaultGeneration else { throw CancellationError() }
        settings.serverURL = session.serverURL.absoluteString
        settings.email = normalizedEmail
        settings.sessionReference = session.tokenReference
        authenticatedSession = session
        isLocked = false
        guard apply(snapshot, generation: generation) else { throw CancellationError() }
        sessionNeedsSignIn = false
        await updatePendingMutationCount()
        guard acceptsVaultResult(generation) else { throw CancellationError() }
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

    func respondToLoginRequest(
        _ request: PendingLoginRequest,
        approved: Bool,
        fingerprintVerified: Bool = false,
        masterPassword: String? = nil
    ) async throws {
        guard let session = authenticatedSession else { throw VaultwardenServiceError.sessionExpired }
        let generation = vaultGeneration
        if approved {
            guard !isLocked else { throw VaultwardenServiceError.vaultLocked }
            guard fingerprintVerified, let phrase = request.fingerprintPhrase, !phrase.isEmpty else {
                throw LoginRequestApprovalError.fingerprintRequired
            }
            if let masterPassword {
                guard !masterPassword.isEmpty else { throw LoginRequestApprovalError.authenticationRequired }
                try await vaultwardenService.verifyMasterPassword(masterPassword, session: session)
            } else {
                guard settings.biometricUnlock, await loginApprovalAuthenticator() else {
                    throw LoginRequestApprovalError.authenticationRequired
                }
            }
            guard generation == vaultGeneration, !isLocked, !Task.isCancelled,
                  authenticatedSession?.tokenReference == session.tokenReference else { throw CancellationError() }
            // Re-fetch after authentication. Never approve a replacement public
            // key or an expired request using a phrase the user saw earlier.
            let pending = try await vaultwardenService.pendingLoginRequests(session: session)
            guard let current = pending.first(where: { $0.id == request.id }),
                  current.publicKey == request.publicKey, current.fingerprintPhrase == phrase else {
                throw LoginRequestApprovalError.requestChanged
            }
            guard generation == vaultGeneration, !isLocked, !Task.isCancelled,
                  authenticatedSession?.tokenReference == session.tokenReference else { throw CancellationError() }
        }
        try await vaultwardenService.respondToLoginRequest(request, approved: approved, session: session)
    }

    func sync() async {
        let generation = vaultGeneration
        guard !isLocked else { return }
        guard !isSyncing else { return }
        guard let authenticatedSession else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try? await syncEngine.retryBlocked(reference: authenticatedSession.tokenReference)
            let flush = await syncEngine.flush(session: authenticatedSession)
            let snapshot = try await vaultwardenService.sync(session: authenticatedSession)
            guard apply(snapshot, generation: generation) else { return }
            await applyPendingProjectionsAndPublish(generation: generation)
            await updatePendingMutationCount()
            guard acceptsVaultResult(generation) else { return }
            userFacingNotice = flush.problemNotice
            lastSyncError = nil
            sessionNeedsSignIn = false
            SecureLog.event("Vault sync completed", logger: SecureLog.sync)
            if !Task.isCancelled {
                Task { await ICloudBackupManager.shared.backUpIfNeeded(from: self) }
            }
        } catch is CancellationError {
            // A caller can intentionally cancel a sync (for example when its view disappears).
            // Cancellation is not a server failure and must not replace a successful last-sync state.
            SecureLog.event("Vault sync cancelled by caller", logger: SecureLog.sync)
        } catch {
            lastSyncError = error.localizedDescription
            if case VaultwardenServiceError.sessionExpired = error {
                sessionNeedsSignIn = true
            }
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
                // This archive contains item fields, not attachment file contents.
                copy.attachments = nil
                return copy
            },
            folders: folders,
            excludedOrganizationItems: items.filter { $0.organization != nil }.count,
            excludedPasskeys: personalItems.reduce(0) { $0 + $1.passkeyCount }
        )
        let archive = try await Task.detached(priority: .userInitiated) {
            try EncryptedVaultArchive.seal(payload, password: password)
        }.value
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(TemporaryVaultFiles.exportFileName(at: Date()))
        // Only the newest export is kept; older ones were already handed off or abandoned.
        TemporaryVaultFiles.removeExports()
        try archive.write(to: url, options: ClientPlatform.protectedFileWritingOptions)
        return url
    }

    func importEncryptedVault(data: Data, password: String) async throws -> VaultArchiveImportSummary {
        let generation = vaultGeneration
        guard authenticatedSession != nil else { throw VaultArchiveError.signedOut }
        guard !isLocked else { throw VaultArchiveError.vaultLocked }
        let payload = try await Task.detached(priority: .userInitiated) {
            try EncryptedVaultArchive.open(data, password: password)
        }.value
        guard acceptsVaultResult(generation) else { throw CancellationError() }

        var importedFolders = 0
        for folder in payload.folders where !folders.contains(where: {
            $0.name.caseInsensitiveCompare(folder.name) == .orderedSame
        }) {
            guard acceptsVaultResult(generation) else { throw CancellationError() }
            if await addFolder(named: folder.name) { importedFolders += 1 }
        }

        var importedItems = 0
        var failedItems = 0
        for archivedItem in payload.items {
            guard acceptsVaultResult(generation) else { throw CancellationError() }
            var item = archivedItem
            item.id = UUID()
            item.organization = nil
            item.collectionIDs = []
            item.deletedAt = nil
            item.archivedAt = nil
            item.createdAt = Date()
            item.passkeyCount = 0
            item.attachments = nil
            item.updatedAt = Date()
            if await save(item) { importedItems += 1 } else { failedItems += 1 }
        }
        return VaultArchiveImportSummary(
            importedItems: importedItems,
            importedFolders: importedFolders,
            failedItems: failedItems
        )
    }

    private func acceptsVaultResult(_ generation: UInt64) -> Bool {
        !isLocked && generation == vaultGeneration
    }

    /// A download that finishes after a lock must not leave plaintext behind.
    private func keepDecryptedFile(_ url: URL, generation: UInt64) -> URL? {
        guard acceptsVaultResult(generation) else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return nil
        }
        return url
    }

    @discardableResult
    private func apply(_ snapshot: EncryptedVaultSnapshot, generation: UInt64) -> Bool {
        guard acceptsVaultResult(generation) else { return false }
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
        if !snapshot.isFromOfflineCache { lastSuccessfulSync = Date() }
        discardSelectionForMissingItem()
        return true
    }

    private func apply(_ projection: VaultMutationProjection, generation: UInt64) {
        guard acceptsVaultResult(generation) else { return }
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

    private func enqueueAndAttempt(_ mutation: PreparedVaultMutation, generation: UInt64) async -> Bool {
        await enqueueAndAttempt([mutation], generation: generation)
    }

    private func enqueueAndAttempt(_ mutations: [PreparedVaultMutation], generation: UInt64) async -> Bool {
        guard acceptsVaultResult(generation) else { return false }
        do {
            for mutation in mutations {
                try await syncEngine.enqueue(mutation)
                guard acceptsVaultResult(generation) else { return false }
                apply(mutation.projection, generation: generation)
            }
            await publishLocalAutoFillIndex(generation: generation)
            await updatePendingMutationCount()
            await flushPendingMutations(refreshVault: true, showDeferredNotice: true)
            guard acceptsVaultResult(generation) else { return false }
            return true // Safely queued is a successful local save, even when offline.
        } catch {
            userFacingNotice = "The encrypted offline change could not be saved: \(error.localizedDescription)"
            SecureLog.failure("Mutation queue write", error: error, logger: SecureLog.sync)
            return false
        }
    }

    private func flushPendingMutations(refreshVault: Bool, showDeferredNotice: Bool) async {
        let generation = vaultGeneration
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
                guard apply(snapshot, generation: generation) else { return }
                // A successful write can be followed by an eventually-consistent
                // `/sync` response that still contains the previous item state.
                // Keep completed non-create projections through this first refresh
                // so rows do not disappear and immediately reappear.
                let completedIDs = Set(result.completedMutationIDs)
                for mutation in mutationsBeforeFlush
                where completedIDs.contains(mutation.id) && !mutation.isCreate {
                    apply(mutation.projection, generation: generation)
                }
                await applyPendingProjectionsAndPublish(generation: generation)
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

    private func applyPendingProjectionsAndPublish(generation: UInt64) async {
        guard let reference = authenticatedSession?.tokenReference,
              let mutations = try? await syncEngine.mutations(reference: reference) else { return }
        guard acceptsVaultResult(generation) else { return }
        for mutation in mutations.sorted(by: { $0.createdAt < $1.createdAt }) {
            apply(mutation.projection, generation: generation)
        }
        if !mutations.isEmpty { await publishLocalAutoFillIndex(generation: generation) }
    }

    private func publishLocalAutoFillIndex(generation: UInt64) async {
        guard acceptsVaultResult(generation) else { return }
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
        let count: Int
        if let reference = authenticatedSession?.tokenReference {
            count = (try? await syncEngine.pendingCount(reference: reference)) ?? 0
        } else {
            count = 0
        }
        // The retry loop calls this every 15 seconds. An unchanged assignment
        // would still publish and redraw every view observing the store.
        if pendingMutationCount != count { pendingMutationCount = count }
    }

    private func startAutomaticRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                guard self.authenticatedSession != nil else { continue }
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
    }

    func appDidEnterBackground(at date: Date = Date()) {
        persistSettingsNow()
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
        vaultGeneration &+= 1
        isLocked = true
        clearVisibleVault()
        selectedItemID = nil
        selectedFilter = nil
        // Decrypted downloads must not outlive the unlocked session on disk.
        Task.detached(priority: .utility) { TemporaryVaultFiles.removePlaintext() }
        let session = authenticatedSession
        let previousLockTask = lockTask
        lockTask = Task { [vaultwardenService] in
            if let previousLockTask { await previousLockTask.value }
            await vaultwardenService.lock(session: session)
        }
    }

    func logoutAndDeleteLocalData() async {
        guard let session = authenticatedSession else { return }
        lock(requestAutomaticUnlock: false)
        if let lockTask { await lockTask.value }
        lockTask = nil
        ICloudBackupManager.shared.resetForSignOut()
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
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        settingsDefaults.removeObject(forKey: Self.settingsStorageKey)
        UserDefaults.standard.removeObject(forKey: "vaultwardenApp.deviceIdentifier")

        authenticatedSession = nil
        clearVisibleVault()
        backgroundedAt = nil
        isLocked = false
        isSyncing = false
        lastSync = Date()
        lastSuccessfulSync = nil
        lastSyncError = nil
        sessionNeedsSignIn = false
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

        TemporaryVaultFiles.removeAll(in: fileManager.temporaryDirectory)
    }

    func unlockWithBiometrics() async -> Bool {
        let generation = vaultGeneration
        let policy = DeviceUnlockPolicy.current
        guard settings.biometricUnlock, DeviceUnlockPolicy.current != .disabled,
              UnlockPresentationPolicy.isAllowed, !Task.isCancelled else { return false }
        do {
            if let lockTask { await lockTask.value }
            guard generation == vaultGeneration else { return false }
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
            guard generation == vaultGeneration else {
                if isLocked { await vaultwardenService.lock(session: authenticatedSession) }
                return false
            }
            guard settings.biometricUnlock, DeviceUnlockPolicy.current == policy else {
                await vaultwardenService.lock(session: authenticatedSession)
                return false
            }
            lastUnlockError = nil
            isLocked = false
            backgroundedAt = nil
            if items.isEmpty {
                await restoreCachedVaultIfAvailable()
            }
            guard acceptsVaultResult(generation) else { return false }
            if items.isEmpty || settings.syncOnOpen {
                Task { await sync() }
            } else {
                Task { await flushPendingMutations(refreshVault: true, showDeferredNotice: false) }
            }
            return true
        } catch {
            lastUnlockError = Self.unlockErrorMessage(error)
            return false
        }
    }

    func unlock(masterPassword: String) async -> Bool {
        let generation = vaultGeneration
        guard !masterPassword.isEmpty else { return false }
        do {
            if let lockTask { await lockTask.value }
            guard generation == vaultGeneration else { return false }
            lockTask = nil
            if let authenticatedSession {
                try await vaultwardenService.unlock(
                    session: authenticatedSession,
                    masterPassword: masterPassword
                )
            }
            guard generation == vaultGeneration else {
                if isLocked { await vaultwardenService.lock(session: authenticatedSession) }
                return false
            }
            lastUnlockError = nil
            isLocked = false
            backgroundedAt = nil
            if items.isEmpty {
                await restoreCachedVaultIfAvailable()
            }
            guard acceptsVaultResult(generation) else { return false }
            if items.isEmpty || settings.syncOnOpen {
                Task { await sync() }
            } else {
                Task { await flushPendingMutations(refreshVault: true, showDeferredNotice: false) }
            }
            return true
        } catch {
            lastUnlockError = Self.unlockErrorMessage(error)
            return false
        }
    }

    /// Nil lets the lock screen show its own wording; a dismissed prompt is not an error.
    private static func unlockErrorMessage(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let keychainError = error as? SessionStoreError, keychainError.isUserCancellation { return nil }
        return error.localizedDescription
    }

    private func restoreCachedVaultIfAvailable() async {
        let generation = vaultGeneration
        guard let session = authenticatedSession else { return }
        do {
            let snapshot = try await vaultwardenService.loadCachedVault(session: session)
            guard apply(snapshot, generation: generation) else { return }
            await applyPendingProjectionsAndPublish(generation: generation)
            await updatePendingMutationCount()
            SecureLog.event("Encrypted offline vault restored", logger: SecureLog.sync)
        } catch {
            // A missing cache is expected on the first login. The normal sync path
            // below will download and seed it when the server is reachable.
        }
    }
}
