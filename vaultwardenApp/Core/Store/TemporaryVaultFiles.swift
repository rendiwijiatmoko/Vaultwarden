import Foundation

/// Scratch files the app writes outside its encrypted stores. Views delete them
/// after use; this sweeps whatever a crash, a force quit, or a lock left behind.
nonisolated enum TemporaryVaultFiles {
    /// Decrypted file contents. Nothing may outlive an unlocked session here.
    static let plaintextDirectories = ["DecryptedAttachments", "DecryptedSends"]
    /// Files staged for an upload that may still be running.
    static let stagingDirectories = [
        "StagedVaultAttachments", "SendSelections", "EncryptedSendUploads", "EncryptedAttachmentUploads"
    ]
    static let exportPrefix = "Vaultwarden-"
    static let exportExtension = "vwvault"

    /// Runs at lock: removes decrypted downloads only, so an upload in flight keeps its file.
    static func removePlaintext(in root: URL = FileManager.default.temporaryDirectory) {
        remove(plaintextDirectories, in: root)
    }

    /// Runs at launch and sign-out, when no transfer can be in progress.
    static func removeAll(in root: URL = FileManager.default.temporaryDirectory) {
        remove(plaintextDirectories + stagingDirectories, in: root)
        removeExports(in: root)
    }

    static func removeExports(in root: URL = FileManager.default.temporaryDirectory, except kept: URL? = nil) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in files where isExport(url) && url.standardizedFileURL != kept?.standardizedFileURL {
            try? fileManager.removeItem(at: url)
        }
    }

    static func isExport(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(exportPrefix) && url.pathExtension == exportExtension
    }

    /// File names are formatted with a fixed POSIX locale so they sort and parse
    /// the same way in every region, calendar, and numbering system.
    static func exportFileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(exportPrefix)\(formatter.string(from: date)).\(exportExtension)"
    }

    private static func remove(_ directories: [String], in root: URL) {
        let fileManager = FileManager.default
        for name in directories {
            try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}
