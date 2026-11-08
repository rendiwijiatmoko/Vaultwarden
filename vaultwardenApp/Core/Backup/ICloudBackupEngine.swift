import Foundation

nonisolated struct ICloudBackupSummary: Identifiable, Equatable, Sendable {
    let fileName: String
    let createdAt: Date
    let keyID: String
    /// Nil when this device doesn't have the backup's key.
    let itemCount: Int?
    let folderCount: Int?

    var id: String { fileName }
    var needsKey: Bool { itemCount == nil }
}

/// The blocking half of iCloud Backup: keychain, crypto and coordinated file access.
/// Every method runs off the main thread, inside detached tasks.
nonisolated struct ICloudBackupEngine: Sendable {
    enum Outcome: Sendable {
        case unchanged
        case backedUp(ICloudBackupSummary, digest: Data)
    }

    let container: any ICloudBackupContainerProviding
    let keyStore: any ICloudBackupKeyStoring

    func isAvailable() -> Bool {
        container.backupsDirectory() != nil
    }

    /// Seals and writes a backup, then trims old ones. Skips the write when `force` is
    /// false and nothing changed since `lastDigest`.
    func backUp(
        _ payload: VaultArchivePayload,
        lastDigest: Data?,
        force: Bool,
        now: Date,
        keeping retainedCount: Int = ICloudBackupSchedule.retainedBackupCount
    ) throws -> Outcome {
        let files = try fileStore()
        let key = try ICloudBackupKeychain.currentKey(in: keyStore)
        let digest = try ICloudBackupArchive.contentDigest(of: payload, key: key)
        if !force, ICloudBackupSchedule.isUnchanged(lastDigest: lastDigest, currentDigest: digest) {
            return .unchanged
        }
        let metadata = ICloudBackupMetadata(
            itemCount: payload.items.count,
            folderCount: payload.folders.count,
            contentDigest: digest
        )
        let backupID = UUID()
        let archive = try ICloudBackupArchive.seal(
            payload,
            metadata: metadata,
            key: key,
            backupID: backupID,
            createdAt: now
        )
        let name = ICloudBackupFileStore.fileName(createdAt: now, backupID: backupID)
        try files.write(archive, named: name)

        // Only after the new backup is safely written.
        if let entries = try? files.entries() {
            for expired in ICloudBackupSchedule.namesToDelete(entries, keeping: retainedCount) where expired != name {
                try? files.delete(named: expired)
            }
        }
        let summary = ICloudBackupSummary(
            fileName: name,
            createdAt: now,
            keyID: key.id,
            itemCount: metadata.itemCount,
            folderCount: metadata.folderCount
        )
        return .backedUp(summary, digest: digest)
    }

    /// Nil when iCloud isn't available. Backups already summarized with their key are reused.
    func listBackups(reusing cached: [String: ICloudBackupSummary]) throws -> [ICloudBackupSummary]? {
        guard let directory = container.backupsDirectory() else { return nil }
        let files = ICloudBackupFileStore(directory: directory)
        return try files.backupFileNames()
            .compactMap { name -> ICloudBackupSummary? in
                if let summary = cached[name], !summary.needsKey { return summary }
                return summarize(name, in: files)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func open(fileName: String) throws -> ICloudBackupContents {
        let files = try fileStore()
        let archive = try files.read(named: fileName)
        let header = try ICloudBackupArchive.header(of: archive)
        guard let key = try ICloudBackupKeychain.key(id: header.keyID, in: keyStore) else {
            throw ICloudBackupError.keyUnavailable
        }
        return try ICloudBackupArchive.open(archive, key: key)
    }

    func delete(fileNames: [String]) throws {
        let files = try fileStore()
        for name in fileNames {
            try files.delete(named: name)
        }
    }

    private func fileStore() throws -> ICloudBackupFileStore {
        guard let directory = container.backupsDirectory() else { throw ICloudBackupError.iCloudUnavailable }
        return ICloudBackupFileStore(directory: directory)
    }

    /// Damaged or unreadable files are left out of the list.
    private func summarize(_ name: String, in files: ICloudBackupFileStore) -> ICloudBackupSummary? {
        guard let archive = try? files.read(named: name),
              let header = try? ICloudBackupArchive.header(of: archive) else { return nil }
        guard let key = try? ICloudBackupKeychain.key(id: header.keyID, in: keyStore) else {
            return ICloudBackupSummary(
                fileName: name,
                createdAt: header.createdAt,
                keyID: header.keyID,
                itemCount: nil,
                folderCount: nil
            )
        }
        guard let opened = try? ICloudBackupArchive.openMetadata(archive, key: key) else { return nil }
        return ICloudBackupSummary(
            fileName: name,
            createdAt: header.createdAt,
            keyID: header.keyID,
            itemCount: opened.metadata.itemCount,
            folderCount: opened.metadata.folderCount
        )
    }
}
