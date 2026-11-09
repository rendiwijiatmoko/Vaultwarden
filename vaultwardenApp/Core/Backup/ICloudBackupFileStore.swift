import Foundation

/// Where backups go. Blocking: Apple asks that the ubiquity container be resolved off
/// the main thread, so call it only from detached work.
nonisolated protocol ICloudBackupContainerProviding: Sendable {
    func backupsDirectory() -> URL?
}

/// The app's iCloud container. `Backups` sits beside Documents, not in it, so the
/// files stay out of the Files app and iCloud Drive's folder.
nonisolated struct UbiquityBackupContainer: ICloudBackupContainerProviding {
    func backupsDirectory() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Backups", isDirectory: true)
    }
}

/// Coordinated, atomic reads and writes of sealed backups in one directory.
nonisolated struct ICloudBackupFileStore: Sendable {
    static let fileExtension = "vwbackup"
    private static let prefix = "backup-"
    private static let placeholderSuffix = ".icloud"

    let directory: URL

    /// "backup-1762594860000-1a2b3c4d.vwbackup": fixed-width milliseconds, so names sort by date.
    static func fileName(createdAt: Date, backupID: UUID) -> String {
        let milliseconds = max(0, Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down)))
        let stamp = String(format: "%013lld", milliseconds)
        let suffix = backupID.uuidString.prefix(8).lowercased()
        return "\(prefix)\(stamp)-\(suffix).\(fileExtension)"
    }

    static func creationDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(".\(fileExtension)") else { return nil }
        let core = name.dropFirst(prefix.count).dropLast(fileExtension.count + 1)
        guard let stamp = core.split(separator: "-").first,
              stamp.count == 13,
              let milliseconds = Int64(stamp) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// Older systems list a file that hasn't downloaded as ".name.icloud".
    static func nameBehindPlaceholder(_ entry: String) -> String? {
        guard entry.hasPrefix("."), entry.hasSuffix(placeholderSuffix) else { return nil }
        let name = String(entry.dropFirst().dropLast(placeholderSuffix.count))
        return name.isEmpty ? nil : name
    }

    /// Newest first. Files that aren't backups are ignored.
    func backupFileNames() throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let entries = try manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        var names = Set<String>()
        for entry in entries {
            if let name = Self.nameBehindPlaceholder(entry) {
                guard Self.creationDate(fromFileName: name) != nil else { continue }
                // Ask iCloud for it now, so the coordinated read that follows finds it sooner.
                try? manager.startDownloadingUbiquitousItem(at: url(for: name))
                names.insert(name)
            } else if Self.creationDate(fromFileName: entry) != nil {
                names.insert(entry)
            }
        }
        return names.sorted(by: >)
    }

    func entries() throws -> [ICloudBackupFileEntry] {
        try backupFileNames().compactMap { name in
            Self.creationDate(fromFileName: name).map { ICloudBackupFileEntry(name: name, createdAt: $0) }
        }
    }

    func write(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try coordinateWriting(url(for: name), options: .forReplacing) { target in
            try data.write(to: target, options: ClientPlatform.encryptedFileWritingOptions)
        }
    }

    func read(named name: String) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        // A coordinated read waits for iCloud to download the file if it isn't local yet.
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url(for: name),
            options: [.withoutChanges],
            error: &coordinationError
        ) { target in
            result = Result(catching: { try Data(contentsOf: target) })
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ICloudBackupError.invalidBackup }
        return try result.get()
    }

    func delete(named name: String) throws {
        try coordinateWriting(url(for: name), options: .forDeleting) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch CocoaError.fileNoSuchFile {
                // Already gone, perhaps from another device.
            }
        }
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private func coordinateWriting(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinationError
        ) { target in
            do { try body(target) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
}
