import Foundation
import Testing
@testable import vaultwardenApp

// MARK: - Fakes

/// Stands in for iCloud Keychain, so no test touches the real keychain.
private nonisolated final class InMemoryBackupKeyStore: ICloudBackupKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data]

    init(keys: [String: Data] = [:]) {
        self.keys = keys
    }

    var count: Int { lock.withLock { keys.count } }

    func keyIDs() throws -> [String] { lock.withLock { Array(keys.keys) } }
    func keyData(for id: String) throws -> Data? { lock.withLock { keys[id] } }
    func add(_ keyData: Data, id: String) throws { lock.withLock { keys[id] = keyData } }
}

private nonisolated struct FixedBackupContainer: ICloudBackupContainerProviding {
    let directory: URL?
    func backupsDirectory() -> URL? { directory }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ICloudBackupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sampleItems() -> [VaultItem] {
    var mail = VaultItem(name: "Mail")
    mail.username = "taylor@example.com"
    mail.password = "correct horse battery staple"
    mail.folder = "Personal"
    mail.passkeyCount = 1
    mail.attachments = [VaultAttachment(id: "a1", fileName: "scan.pdf", size: 1_024)]
    mail.customFields = [VaultCustomField(name: "PIN", value: "1234", type: .hidden)]

    var bank = VaultItem(name: "Bank")
    bank.password = "hunter2"

    var shared = VaultItem(name: "Team Wiki")
    shared.organization = "Acme"

    var trashed = VaultItem(name: "Old Forum")
    trashed.deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

    return [mail, bank, shared, trashed]
}

private func samplePayload(exportedAt: Date = Date(timeIntervalSince1970: 1_794_130_860)) -> VaultArchivePayload {
    ICloudBackupArchive.payload(
        items: sampleItems(),
        folders: [VaultFolder(name: "Personal")],
        exportedAt: exportedAt
    )
}

private func makeKey() throws -> ICloudBackupKey {
    try ICloudBackupKey.generate()
}

private func seal(
    _ payload: VaultArchivePayload,
    key: ICloudBackupKey,
    backupID: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1_794_130_860)
) throws -> Data {
    let metadata = ICloudBackupMetadata(
        itemCount: payload.items.count,
        folderCount: payload.folders.count,
        contentDigest: try ICloudBackupArchive.contentDigest(of: payload, key: key)
    )
    return try ICloudBackupArchive.seal(payload, metadata: metadata, key: key, backupID: backupID, createdAt: createdAt)
}

private func utcCalendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return calendar
}

private let englishUS = Locale(identifier: "en_US")
/// Sunday, November 8, 2026 at 9:41 AM UTC.
private let now = Date(timeIntervalSince1970: 1_794_130_860)
private let hour: TimeInterval = 60 * 60
private let day: TimeInterval = 24 * hour

// MARK: - Archive

@Suite("iCloud Backup archive")
struct ICloudBackupArchiveTests {
    @Test("The payload matches the encrypted export: personal, live items without attachments or passkeys")
    func payloadMatchesExport() {
        let payload = samplePayload()

        #expect(payload.items.map(\.name) == ["Mail", "Bank"])
        #expect(payload.items.allSatisfy { $0.attachments == nil && $0.passkeyCount == 0 })
        #expect(payload.excludedOrganizationItems == 1)
        #expect(payload.excludedPasskeys == 1)
    }

    @Test("Sealing then opening gives back the items, folders and counts")
    func roundTrip() throws {
        let key = try makeKey()
        let payload = samplePayload()
        let backupID = UUID()
        let archive = try seal(payload, key: key, backupID: backupID)

        let contents = try ICloudBackupArchive.open(archive, key: key)

        #expect(contents.header.backupID == backupID)
        #expect(contents.header.keyID == key.id)
        #expect(contents.metadata.itemCount == 2)
        #expect(contents.metadata.folderCount == 1)
        #expect(contents.payload.items.map(\.id) == payload.items.map(\.id))
        #expect(contents.payload.items.first?.password == "correct horse battery staple")
        #expect(contents.payload.folders.map(\.name) == ["Personal"])
    }

    @Test("The sealed file holds no plaintext")
    func noPlaintextOnDisk() throws {
        let archive = try seal(samplePayload(), key: try makeKey())
        let text = String(decoding: archive, as: UTF8.self)

        #expect(!text.contains("correct horse"))
        #expect(!text.contains("taylor@example.com"))
        #expect(!text.contains("Mail"))
    }

    @Test("The header names its key without the key, so restore can choose one")
    func headerNamesKey() throws {
        let key = try makeKey()
        let archive = try seal(samplePayload(), key: key)

        #expect(try ICloudBackupArchive.header(of: archive).keyID == key.id)
    }

    @Test("A different key can't open a backup")
    func wrongKeyFails() throws {
        let archive = try seal(samplePayload(), key: try makeKey())
        let otherKey = try makeKey()

        #expect(throws: ICloudBackupError.authenticationFailed) {
            try ICloudBackupArchive.open(archive, key: otherKey)
        }
        #expect(throws: ICloudBackupError.authenticationFailed) {
            try ICloudBackupArchive.openMetadata(archive, key: otherKey)
        }
    }

    @Test("Changing the header breaks authentication")
    func tamperedHeaderFails() throws {
        let key = try makeKey()
        let archive = try seal(samplePayload(), key: key)

        var envelope = try #require(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let headerData = try #require((envelope["header"] as? String).flatMap { Data(base64Encoded: $0) })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var header = try decoder.decode(ICloudBackupHeader.self, from: headerData)
        header.createdAt = header.createdAt.addingTimeInterval(-day)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        envelope["header"] = try encoder.encode(header).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)

        #expect(throws: ICloudBackupError.authenticationFailed) {
            try ICloudBackupArchive.open(tampered, key: key)
        }
    }

    @Test("Metadata sealed for one backup can't be moved into another")
    func swappedMetadataFails() throws {
        let key = try makeKey()
        let first = try seal(samplePayload(), key: key)
        let second = try seal(samplePayload(), key: key)

        var envelope = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let other = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
        envelope["metadata"] = other["metadata"]
        let spliced = try JSONSerialization.data(withJSONObject: envelope)

        #expect(throws: ICloudBackupError.authenticationFailed) {
            try ICloudBackupArchive.openMetadata(spliced, key: key)
        }
    }

    @Test("Something that isn't a backup is rejected")
    func invalidArchive() {
        #expect(throws: ICloudBackupError.invalidBackup) {
            try ICloudBackupArchive.header(of: Data("not a backup".utf8))
        }
    }

    @Test("The digest ignores what every sync rebuilds, but not a changed password")
    func digestFollowsContentOnly() throws {
        let key = try makeKey()
        let payload = samplePayload()
        let original = try ICloudBackupArchive.contentDigest(of: payload, key: key)

        let resynced = payload.items.reversed().map { item in
            var copy = item
            copy.risks = [.weak]
            copy.customFields = copy.customFields.map { field in
                var fresh = field
                fresh.id = UUID()
                return fresh
            }
            return copy
        }
        let resyncedPayload = ICloudBackupArchive.payload(items: resynced, folders: payload.folders, exportedAt: now.addingTimeInterval(day))
        #expect(try ICloudBackupArchive.contentDigest(of: resyncedPayload, key: key) == original)

        var changed = payload.items
        changed[1].password = "a new password"
        let changedPayload = ICloudBackupArchive.payload(items: changed, folders: payload.folders, exportedAt: now)
        #expect(try ICloudBackupArchive.contentDigest(of: changedPayload, key: key) != original)
    }
}

// MARK: - Keys

@Suite("iCloud Backup keys")
struct ICloudBackupKeyTests {
    @Test("The first backup makes a key; later ones reuse it")
    func currentKeyIsCreatedOnce() throws {
        let store = InMemoryBackupKeyStore()

        let first = try ICloudBackupKeychain.currentKey(in: store)
        let second = try ICloudBackupKeychain.currentKey(in: store)

        #expect(first == second)
        #expect(store.count == 1)
        #expect(first.data.count == 32)
    }

    @Test("Two devices that each made a key settle on the same one")
    func keysConverge() throws {
        let a = try makeKey()
        let b = try makeKey()
        let store = InMemoryBackupKeyStore(keys: [a.id: a.data, b.id: b.data])

        #expect(try ICloudBackupKeychain.currentKey(in: store).id == min(a.id, b.id))
    }

    @Test("Bytes stored under the wrong ID aren't used")
    func mismatchedKeyIsIgnored() throws {
        let real = try makeKey()
        let other = try makeKey()
        let store = InMemoryBackupKeyStore(keys: [real.id: other.data])

        #expect(try ICloudBackupKeychain.key(id: real.id, in: store) == nil)
    }
}

// MARK: - Schedule

@Suite("iCloud Backup schedule")
struct ICloudBackupScheduleTests {
    @Test(
        "Backups are due after their interval, with an hour of slack",
        arguments: [
            (nil, ICloudBackupFrequency.daily, true),
            (22 * hour, .daily, false),
            (23 * hour, .daily, true),
            (30 * hour, .daily, true),
            (6 * day + 22 * hour, .weekly, false),
            (6 * day + 23 * hour, .weekly, true),
            (-2 * hour, .daily, true)
        ] as [(TimeInterval?, ICloudBackupFrequency, Bool)]
    )
    func isDue(elapsed: TimeInterval?, frequency: ICloudBackupFrequency, expected: Bool) {
        let lastBackup = elapsed.map { now.addingTimeInterval(-$0) }
        #expect(ICloudBackupSchedule.isDue(lastBackup: lastBackup, frequency: frequency, now: now) == expected)
    }

    @Test("An unchanged vault is skipped; a changed or unknown one isn't")
    func unchangedSkip() {
        let digest = Data([1, 2, 3])
        #expect(ICloudBackupSchedule.isUnchanged(lastDigest: digest, currentDigest: Data([1, 2, 3])))
        #expect(!ICloudBackupSchedule.isUnchanged(lastDigest: digest, currentDigest: Data([4, 5, 6])))
        #expect(!ICloudBackupSchedule.isUnchanged(lastDigest: nil, currentDigest: digest))
    }

    @Test("Retention keeps the newest and deletes the rest")
    func retentionDeletesOldest() {
        let entries = (0..<12).map { index in
            ICloudBackupFileEntry(name: "backup-\(index)", createdAt: now.addingTimeInterval(-Double(index) * day))
        }.shuffled()

        let deleted = ICloudBackupSchedule.namesToDelete(entries, keeping: 10)

        #expect(Set(deleted) == ["backup-10", "backup-11"])
    }

    @Test("Retention deletes nothing until there are more than it keeps, and always keeps one")
    func retentionEdges() {
        let entries = (0..<3).map { ICloudBackupFileEntry(name: "b\($0)", createdAt: now.addingTimeInterval(-Double($0) * day)) }

        #expect(ICloudBackupSchedule.namesToDelete(entries, keeping: 10).isEmpty)
        #expect(ICloudBackupSchedule.namesToDelete(entries, keeping: 0) == ["b1", "b2"])
    }
}

// MARK: - Files and engine

@Suite("iCloud Backup files")
struct ICloudBackupFileTests {
    @Test("File names carry their date and sort newest last-to-first")
    func fileNames() throws {
        let date = Date(timeIntervalSince1970: 1_794_130_860.123)
        let name = ICloudBackupFileStore.fileName(createdAt: date, backupID: UUID())
        let parsed = try #require(ICloudBackupFileStore.creationDate(fromFileName: name))

        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
        #expect(name.hasSuffix(".vwbackup"))
        #expect(ICloudBackupFileStore.creationDate(fromFileName: "notes.txt") == nil)
        #expect(ICloudBackupFileStore.nameBehindPlaceholder(".\(name).icloud") == name)
        #expect(ICloudBackupFileStore.nameBehindPlaceholder(name) == nil)
    }

    @Test("Back up, list, skip when unchanged, open")
    func engineRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ICloudBackupEngine(container: FixedBackupContainer(directory: directory), keyStore: InMemoryBackupKeyStore())
        let payload = samplePayload()

        let outcome = try engine.backUp(payload, lastDigest: nil, force: false, now: now)
        guard case let .backedUp(summary, digest) = outcome else {
            Issue.record("Expected a backup")
            return
        }
        #expect(summary.itemCount == 2)

        let unchanged = try engine.backUp(payload, lastDigest: digest, force: false, now: now.addingTimeInterval(day))
        guard case .unchanged = unchanged else {
            Issue.record("An unchanged vault should be skipped")
            return
        }

        let listed = try #require(try engine.listBackups(reusing: [:]))
        #expect(listed.map(\.fileName) == [summary.fileName])
        #expect(listed.first?.needsKey == false)

        let contents = try engine.open(fileName: summary.fileName)
        #expect(contents.payload.items.map(\.name) == ["Mail", "Bank"])
    }

    @Test("Back Up Now writes even when nothing changed, and retention trims old backups")
    func forcedBackupsAndRetention() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ICloudBackupEngine(container: FixedBackupContainer(directory: directory), keyStore: InMemoryBackupKeyStore())
        let payload = samplePayload()

        for index in 0..<5 {
            _ = try engine.backUp(payload, lastDigest: nil, force: true, now: now.addingTimeInterval(Double(index) * day), keeping: 3)
        }

        let listed = try #require(try engine.listBackups(reusing: [:]))
        #expect(listed.count == 3)
        #expect(listed.first?.createdAt == now.addingTimeInterval(4 * day))
    }

    @Test("A device without the backup's key lists it as needing one, and can't open it")
    func missingKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = FixedBackupContainer(directory: directory)
        let writer = ICloudBackupEngine(container: container, keyStore: InMemoryBackupKeyStore())
        _ = try writer.backUp(samplePayload(), lastDigest: nil, force: true, now: now)

        let reader = ICloudBackupEngine(container: container, keyStore: InMemoryBackupKeyStore())
        let listed = try #require(try reader.listBackups(reusing: [:]))
        let summary = try #require(listed.first)

        #expect(summary.needsKey)
        #expect(throws: ICloudBackupError.keyUnavailable) {
            try reader.open(fileName: summary.fileName)
        }
    }

    @Test("Without iCloud, nothing is written and listing says so")
    func iCloudUnavailable() throws {
        let engine = ICloudBackupEngine(container: FixedBackupContainer(directory: nil), keyStore: InMemoryBackupKeyStore())

        #expect(throws: ICloudBackupError.iCloudUnavailable) {
            try engine.backUp(samplePayload(), lastDigest: nil, force: true, now: now)
        }
        #expect(try engine.listBackups(reusing: [:]) == nil)
    }
}

// MARK: - Status words

@Suite("iCloud Backup status")
struct ICloudBackupStatusTests {
    private func status(
        isEnabled: Bool = true,
        available: Bool? = true,
        activity: ICloudBackupActivity = .idle,
        problem: ICloudBackupProblem? = nil,
        lastBackup: Date? = nil
    ) -> ICloudBackupStatus {
        ICloudBackupStatus.resolve(
            isEnabled: isEnabled,
            isICloudAvailable: available,
            activity: activity,
            problem: problem,
            lastBackup: lastBackup,
            frequency: .daily
        )
    }

    @Test("Activity outranks iCloud, which outranks failures, which outrank the schedule")
    func resolveOrder() {
        #expect(status(available: false, activity: .backingUp) == .backingUp)
        #expect(status(available: false, problem: .failed) == .iCloudUnavailable(isEnabled: true))
        #expect(status(isEnabled: false, problem: .storageFull) == .needsAttention(.storageFull))
        #expect(status(isEnabled: false, lastBackup: now) == .off(lastBackup: now))
        #expect(status() == .notBackedUpYet(.daily))
        #expect(status(lastBackup: now) == .backedUp(now))
        // Unknown availability doesn't flash a warning.
        #expect(status(available: nil) == .notBackedUpYet(.daily))
    }

    @Test("Root row values")
    func rootValues() throws {
        let calendar = try utcCalendar()
        func value(_ status: ICloudBackupStatus) -> String {
            status.rootValue(now: now, calendar: calendar, locale: englishUS)
        }

        #expect(value(.off(lastBackup: nil)) == "Off")
        #expect(value(.iCloudUnavailable(isEnabled: false)) == "Off")
        #expect(value(.iCloudUnavailable(isEnabled: true)) == "iCloud Off")
        #expect(value(.backingUp) == "Backing Up…")
        #expect(value(.needsAttention(.failed)) == "Needs Attention")
        #expect(value(.notBackedUpYet(.weekly)) == "Every Week")
        #expect(value(.backedUp(now.addingTimeInterval(-2 * hour))) == "Today")
        // 8:00 PM the evening before is yesterday, though less than a day ago.
        #expect(value(.backedUp(Date(timeIntervalSince1970: 1_794_081_600))) == "Yesterday")
        #expect(value(.backedUp(Date(timeIntervalSince1970: 1_793_698_860))) == "Nov 3")
        #expect(value(.backedUp(Date(timeIntervalSince1970: 1_762_162_860))) == "Nov 3, 2025")
    }

    @Test("Hero lines")
    func heroLines() throws {
        let calendar = try utcCalendar()
        func line(_ status: ICloudBackupStatus) -> String {
            status.line(now: now, calendar: calendar, locale: englishUS)
        }
        let earlier = now.addingTimeInterval(-hour)
        let time = ICloudBackupWords.time(earlier, calendar: calendar, locale: englishUS)

        #expect(line(.backedUp(earlier)) == "Last backup: Today at \(time)")
        #expect(line(.off(lastBackup: earlier)) == "Last backup: Today at \(time)")
        #expect(line(.off(lastBackup: nil)) == "Keep an encrypted copy of your vault in iCloud.")
        #expect(line(.iCloudUnavailable(isEnabled: true)) == "Turn on iCloud Drive to back up")
        #expect(line(.needsAttention(.storageFull)) == "Couldn’t back up · iCloud storage is full")
        #expect(line(.notBackedUpYet(.daily)) == "Not backed up yet")
    }

    @Test("Only problems are toned")
    func tones() {
        #expect(ICloudBackupStatus.needsAttention(.failed).tone == .failure)
        #expect(ICloudBackupStatus.iCloudUnavailable(isEnabled: true).tone == .attention)
        #expect(ICloudBackupStatus.backedUp(now).tone == .plain)
    }

    @Test("A full iCloud is told apart from other failures")
    func problemMapping() {
        #expect(ICloudBackupProblem(CocoaError(.fileWriteOutOfSpace)) == .storageFull)
        #expect(ICloudBackupProblem(CocoaError(.fileWriteUnknown)) == .failed)
        #expect(ICloudBackupProblem(ICloudBackupError.keychain(-25_300)) == .failed)
    }

    @Test("The schedule footer follows the choice")
    func scheduleFooter() {
        #expect(ICloudBackupWords.scheduleFooter(isEnabled: false, frequency: .daily, isICloudAvailable: true)
                == "Vaultwarden backs up only when you choose Back Up Now.")
        #expect(ICloudBackupWords.scheduleFooter(isEnabled: true, frequency: .weekly, isICloudAvailable: true)
            .hasPrefix("Backs up once a week"))
        #expect(ICloudBackupWords.scheduleFooter(isEnabled: true, frequency: .daily, isICloudAvailable: false)
            .hasPrefix("To back up, turn on iCloud Drive"))
    }
}
