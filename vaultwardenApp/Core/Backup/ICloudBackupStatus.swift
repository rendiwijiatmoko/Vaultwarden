import Foundation

nonisolated enum ICloudBackupFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly

    var id: Self { self }

    var interval: TimeInterval {
        switch self {
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    /// Reads as the sentence it completes: "Back Up: Every Day".
    var title: String {
        switch self {
        case .daily: L10n.string("Every Day")
        case .weekly: L10n.string("Every Week")
        }
    }
}

nonisolated enum ICloudBackupActivity: Equatable, Sendable {
    case idle
    case backingUp
    case restoring
    case deleting
}

nonisolated enum ICloudBackupProblem: Equatable, Sendable {
    case storageFull
    case failed

    init(_ error: any Error) {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace {
            self = .storageFull
            return
        }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (underlying?.domain == NSCocoaErrorDomain && underlying?.code == NSFileWriteOutOfSpaceError) {
            self = .storageFull
        } else {
            self = .failed
        }
    }
}

/// Where iCloud Backup stands. Every surface (hero, root row, Mac row) reads from this,
/// so they can never disagree.
nonisolated enum ICloudBackupStatus: Equatable, Sendable {
    case off(lastBackup: Date?)
    case iCloudUnavailable(isEnabled: Bool)
    case backingUp
    case restoring
    case needsAttention(ICloudBackupProblem)
    case notBackedUpYet(ICloudBackupFrequency)
    case backedUp(Date)

    /// Activity first, then what the system allows, then failures, then the schedule.
    static func resolve(
        isEnabled: Bool,
        isICloudAvailable: Bool?,
        activity: ICloudBackupActivity,
        problem: ICloudBackupProblem?,
        lastBackup: Date?,
        frequency: ICloudBackupFrequency
    ) -> ICloudBackupStatus {
        switch activity {
        case .backingUp: return .backingUp
        case .restoring: return .restoring
        case .idle, .deleting: break
        }
        // Unknown counts as available, so the page doesn't flash a warning while iCloud answers.
        if isICloudAvailable == false { return .iCloudUnavailable(isEnabled: isEnabled) }
        if let problem { return .needsAttention(problem) }
        guard isEnabled else { return .off(lastBackup: lastBackup) }
        guard let lastBackup else { return .notBackedUpYet(frequency) }
        return .backedUp(lastBackup)
    }

    /// The hero's status line.
    func line(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case .off(nil):
            L10n.string("Keep an encrypted copy of your vault in iCloud.")
        case let .off(.some(date)), let .backedUp(date):
            ICloudBackupWords.lastBackupLine(date, now: now, calendar: calendar, locale: locale)
        case .iCloudUnavailable:
            L10n.string("Turn on iCloud Drive to back up")
        case .backingUp:
            L10n.string("Backing up…")
        case .restoring:
            L10n.string("Restoring…")
        case .needsAttention(.storageFull):
            L10n.string("Couldn’t back up · iCloud storage is full")
        case .needsAttention(.failed):
            L10n.string("Couldn’t back up · try again later")
        case .notBackedUpYet:
            L10n.string("Not backed up yet")
        }
    }

    /// The short value on a Settings root row.
    func rootValue(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case .off, .iCloudUnavailable(isEnabled: false):
            L10n.string("Off")
        case .iCloudUnavailable(isEnabled: true):
            L10n.string("iCloud Off")
        case .backingUp:
            L10n.string("Backing Up…")
        case .restoring:
            L10n.string("Restoring…")
        case .needsAttention:
            L10n.string("Needs Attention")
        case let .notBackedUpYet(frequency):
            frequency.title
        case let .backedUp(date):
            ICloudBackupWords.relativeDay(date, now: now, calendar: calendar, locale: locale)
        }
    }

    var tone: StatusTone {
        switch self {
        case .iCloudUnavailable: .attention
        case .needsAttention: .failure
        case .off, .backingUp, .restoring, .notBackedUpYet, .backedUp: .plain
        }
    }
}

nonisolated enum ICloudBackupWords {
    /// "Last backup: Today at 9:41 AM", "Last backup: Yesterday at 9:41 AM", "Last backup: Nov 3 at 9:41 AM".
    static func lastBackupLine(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = self.time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.format("Last backup: Today at %@", time)
        }
        if isYesterday(date, now: now, calendar: calendar) {
            return L10n.format("Last backup: Yesterday at %@", time)
        }
        return L10n.format("Last backup: %@ at %@", shortDate(date, now: now, calendar: calendar, locale: locale), time)
    }

    /// "Today", "Yesterday", or a short date such as "Nov 3".
    static func relativeDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.string("Today") }
        if isYesterday(date, now: now, calendar: calendar) { return L10n.string("Yesterday") }
        return shortDate(date, now: now, calendar: calendar, locale: locale)
    }

    /// A backup row's title: "Today", "Yesterday", a weekday within the last week, else a date.
    static func rowTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.string("Today") }
        if isYesterday(date, now: now, calendar: calendar) { return L10n.string("Yesterday") }
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday),
           date >= weekAgo, date < startOfToday {
            return date.formatted(base.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(base.month(.wide).day())
        }
        return date.formatted(base.month(.wide).day().year())
    }

    /// The schedule group's footer: the consequence of the current choice, or the way to fix iCloud.
    static func scheduleFooter(isEnabled: Bool, frequency: ICloudBackupFrequency, isICloudAvailable: Bool?) -> String {
        if isICloudAvailable == false {
            #if os(macOS)
            return L10n.string("To back up, turn on iCloud Drive in System Settings ▸ Apple Account ▸ iCloud.")
            #else
            return L10n.string("To back up, turn on iCloud Drive in Settings ▸ Apple Account ▸ iCloud.")
            #endif
        }
        guard isEnabled else { return L10n.string("Vaultwarden backs up only when you choose Back Up Now.") }
        switch frequency {
        case .daily:
            return L10n.format(
                "Backs up once a day after your vault syncs, if anything changed. The %lld most recent backups are kept.",
                ICloudBackupSchedule.retainedBackupCount
            )
        case .weekly:
            return L10n.format(
                "Backs up once a week after your vault syncs, if anything changed. The %lld most recent backups are kept.",
                ICloudBackupSchedule.retainedBackupCount
            )
        }
    }

    static var privacyFooter: String {
        L10n.string("Backups are end-to-end encrypted with a key in your iCloud Keychain, so Apple can’t read them. Organization items, attachments and passkeys aren’t included.")
    }

    static var missingKeyFooter: String {
        L10n.string("Backups marked Needs Key were made with a key from iCloud Keychain that isn’t on this device yet.")
    }

    static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        ))
    }

    /// "November 3 at 9:41 AM", for confirmation messages.
    static func moment(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(
            date: .long,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        ))
    }

    private static func shortDate(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(base.month(.abbreviated).day())
        }
        return date.formatted(base.month(.abbreviated).day().year())
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}

nonisolated struct ICloudBackupFileEntry: Equatable, Sendable {
    let name: String
    let createdAt: Date
}

nonisolated enum ICloudBackupSchedule {
    static let retainedBackupCount = 10
    /// A sync that lands a little earlier than yesterday's still counts as a new day.
    static let slack: TimeInterval = 60 * 60

    static func isDue(lastBackup: Date?, frequency: ICloudBackupFrequency, now: Date) -> Bool {
        guard let lastBackup else { return true }
        let elapsed = now.timeIntervalSince(lastBackup)
        // A clock set back would otherwise postpone every backup until it caught up.
        if elapsed < -slack { return true }
        return elapsed >= frequency.interval - slack
    }

    static func isUnchanged(lastDigest: Data?, currentDigest: Data) -> Bool {
        guard let lastDigest else { return false }
        return lastDigest == currentDigest
    }

    /// Everything but the `count` newest backups. At least one is always kept.
    static func namesToDelete(_ entries: [ICloudBackupFileEntry], keeping count: Int = retainedBackupCount) -> [String] {
        let sorted = entries.sorted {
            $0.createdAt == $1.createdAt ? $0.name > $1.name : $0.createdAt > $1.createdAt
        }
        return sorted.dropFirst(max(1, count)).map(\.name)
    }
}
