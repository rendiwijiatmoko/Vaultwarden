import Combine
import Foundation

nonisolated struct ICloudBackupRestoreProgress: Equatable, Sendable {
    var completed: Int
    let total: Int
}

nonisolated struct ICloudBackupRestoreResult: Equatable, Sendable {
    let restoredItems: Int
    let failedItems: Int
    let restoredFolders: Int
    let backupDate: Date
}

/// Encrypted copies of the personal vault in the app's iCloud container, sealed with a
/// key that lives in iCloud Keychain.
@MainActor
final class ICloudBackupManager: ObservableObject {
    static let shared = ICloudBackupManager()

    private enum StorageKey {
        static let enabled = "iCloudBackup.enabled"
        static let frequency = "iCloudBackup.frequency"
        static let lastBackupDate = "iCloudBackup.lastBackupDate"
        static let lastDigest = "iCloudBackup.lastContentDigest"
    }

    /// Off until the person turns it on: it uploads their vault, so it's their call.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: StorageKey.enabled) }
    }
    @Published var frequency: ICloudBackupFrequency {
        didSet { defaults.set(frequency.rawValue, forKey: StorageKey.frequency) }
    }
    /// Nil until iCloud has answered.
    @Published private(set) var isICloudAvailable: Bool?
    @Published private(set) var activity: ICloudBackupActivity = .idle
    @Published private(set) var problem: ICloudBackupProblem?
    /// Newest first.
    @Published private(set) var backups: [ICloudBackupSummary] = []
    @Published private(set) var hasLoadedBackups = false
    @Published private(set) var restoreProgress: ICloudBackupRestoreProgress?
    /// The newest backup in iCloud, from any device.
    @Published private(set) var lastBackupDate: Date?

    private let defaults: UserDefaults
    private let engine: ICloudBackupEngine
    private let now: () -> Date
    private var summaryCache: [String: ICloudBackupSummary] = [:]
    private var identityObserver: (any NSObjectProtocol)?
    private var refreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        keyStore: any ICloudBackupKeyStoring = ICloudKeychainBackupKeyStore(),
        container: any ICloudBackupContainerProviding = UbiquityBackupContainer(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        engine = ICloudBackupEngine(container: container, keyStore: keyStore)
        self.now = now
        isEnabled = defaults.bool(forKey: StorageKey.enabled)
        frequency = defaults.string(forKey: StorageKey.frequency)
            .flatMap(ICloudBackupFrequency.init(rawValue:)) ?? .daily
        lastBackupDate = defaults.object(forKey: StorageKey.lastBackupDate) as? Date
        // The identity token is cheap and safe on the main thread; the container isn't.
        if container is UbiquityBackupContainer, FileManager.default.ubiquityIdentityToken == nil {
            isICloudAvailable = false
        }
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
    }

    var status: ICloudBackupStatus {
        ICloudBackupStatus.resolve(
            isEnabled: isEnabled,
            isICloudAvailable: isICloudAvailable,
            activity: activity,
            problem: problem,
            lastBackup: lastBackupDate,
            frequency: frequency
        )
    }

    /// "Off", "Today", "Yesterday", "Nov 3", "iCloud Off", "Backing Up…", "Needs Attention".
    var rootRowValue: String { status.rootValue(now: now()) }

    var statusLine: String { status.line(now: now()) }

    var canBackUp: Bool { activity == .idle && isICloudAvailable != false }

    // MARK: - Backing up

    /// Called after each successful unlocked sync. Does nothing unless automatic backup is
    /// on, the vault is unlocked, a backup is due and the vault changed since the last one.
    func backUpIfNeeded(from store: AppStore) async {
        guard isEnabled, activity == .idle, store.isAuthenticated, !store.isLocked else { return }
        guard ICloudBackupSchedule.isDue(lastBackup: lastBackupDate, frequency: frequency, now: now()) else { return }
        // A vault that briefly reads empty shouldn't become a backup on its own.
        guard store.items.contains(where: { !$0.isDeleted && $0.organization == nil }) else { return }
        await performBackup(from: store, force: false)
    }

    /// True when the vault is safely in iCloud afterwards.
    @discardableResult
    func backUpNow(from store: AppStore) async -> Bool {
        await performBackup(from: store, force: true)
    }

    @discardableResult
    private func performBackup(from store: AppStore, force: Bool) async -> Bool {
        guard activity == .idle, store.isAuthenticated, !store.isLocked else { return false }
        let date = now()
        let payload = ICloudBackupArchive.payload(items: store.items, folders: store.folders, exportedAt: date)
        // With nothing left in iCloud, an unchanged vault still needs a backup.
        let lastDigest = hasLoadedBackups && backups.isEmpty ? nil : defaults.data(forKey: StorageKey.lastDigest)
        let engine = engine
        let priority: TaskPriority = force ? .userInitiated : .utility
        activity = .backingUp
        let result = await Task.detached(priority: priority) {
            Result(catching: {
                try engine.backUp(payload, lastDigest: lastDigest, force: force, now: date)
            })
        }.value
        activity = .idle

        switch result {
        case .success(.unchanged):
            isICloudAvailable = true
            problem = nil
            return true
        case let .success(.backedUp(summary, digest)):
            isICloudAvailable = true
            problem = nil
            defaults.set(digest, forKey: StorageKey.lastDigest)
            summaryCache[summary.fileName] = summary
            setLastBackupDate(max(summary.createdAt, lastBackupDate ?? .distantPast))
            await refresh()
            return true
        case let .failure(error):
            if (error as? ICloudBackupError) == .iCloudUnavailable {
                isICloudAvailable = false
            } else {
                problem = ICloudBackupProblem(error)
                SecureLog.failure("iCloud backup", error: error, logger: SecureLog.sync)
            }
            return false
        }
    }

    // MARK: - Listing

    func refresh() async {
        let engine = engine
        let cached = summaryCache
        let result = await Task.detached(priority: .utility) {
            Result(catching: { try engine.listBackups(reusing: cached) })
        }.value
        switch result {
        case .success(nil):
            isICloudAvailable = false
        case let .success(.some(summaries)):
            isICloudAvailable = true
            apply(summaries)
        case let .failure(error):
            // The folder exists but couldn't be listed; keep what's shown.
            isICloudAvailable = true
            SecureLog.failure("iCloud backup listing", error: error, logger: SecureLog.sync)
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func apply(_ summaries: [ICloudBackupSummary]) {
        backups = summaries
        hasLoadedBackups = true
        summaryCache = Dictionary(summaries.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        setLastBackupDate(summaries.first?.createdAt)
        if summaries.isEmpty { defaults.removeObject(forKey: StorageKey.lastDigest) }
    }

    private func setLastBackupDate(_ date: Date?) {
        lastBackupDate = date
        if let date {
            defaults.set(date, forKey: StorageKey.lastBackupDate)
        } else {
            defaults.removeObject(forKey: StorageKey.lastBackupDate)
        }
    }

    // MARK: - Restoring and deleting

    /// Adds the backup's items to the vault as new items, as importing an export does.
    /// Nothing already in the vault is changed.
    func restore(_ backup: ICloudBackupSummary, into store: AppStore) async throws -> ICloudBackupRestoreResult {
        let generation = store.vaultGeneration
        guard store.isAuthenticated else { throw ICloudBackupError.signedOut }
        guard !store.isLocked else { throw ICloudBackupError.vaultLocked }
        guard activity == .idle else { throw CancellationError() }
        activity = .restoring
        defer {
            activity = .idle
            restoreProgress = nil
        }

        let engine = engine
        let fileName = backup.fileName
        let contents = try await Task.detached(priority: .userInitiated) {
            try engine.open(fileName: fileName)
        }.value
        guard accepts(store, generation: generation) else { throw CancellationError() }

        var restoredFolders = 0
        for folder in contents.payload.folders where !store.folders.contains(where: {
            $0.name.caseInsensitiveCompare(folder.name) == .orderedSame
        }) {
            guard accepts(store, generation: generation) else { throw CancellationError() }
            if await store.addFolder(named: folder.name) { restoredFolders += 1 }
        }

        let items = contents.payload.items
        restoreProgress = ICloudBackupRestoreProgress(completed: 0, total: items.count)
        var restoredItems = 0
        var failedItems = 0
        for archivedItem in items {
            guard accepts(store, generation: generation) else { throw CancellationError() }
            var item = archivedItem
            item.id = UUID()
            item.organization = nil
            item.collectionIDs = []
            item.deletedAt = nil
            item.archivedAt = nil
            item.createdAt = now()
            item.passkeyCount = 0
            item.attachments = nil
            item.updatedAt = now()
            if await store.save(item) { restoredItems += 1 } else { failedItems += 1 }
            restoreProgress?.completed += 1
        }
        return ICloudBackupRestoreResult(
            restoredItems: restoredItems,
            failedItems: failedItems,
            restoredFolders: restoredFolders,
            backupDate: contents.header.createdAt
        )
    }

    func delete(_ targets: [ICloudBackupSummary]) async throws {
        guard activity == .idle, !targets.isEmpty else { return }
        activity = .deleting
        defer { activity = .idle }
        let engine = engine
        let names = targets.map(\.fileName)
        do {
            try await Task.detached(priority: .userInitiated) {
                try engine.delete(fileNames: names)
            }.value
        } catch {
            await refresh()
            throw error
        }
        let removed = Set(names)
        apply(backups.filter { !removed.contains($0.fileName) })
    }

    /// The same guard the store uses: work started before a lock never lands after it.
    private func accepts(_ store: AppStore, generation: UInt64) -> Bool {
        !store.isLocked && store.vaultGeneration == generation && !Task.isCancelled
    }
}
