import Foundation
import LocalAuthentication

/// How a status line should read: plain, needs the person (orange), or failed (red).
nonisolated enum StatusTone: Equatable, Sendable {
    case plain, attention, failure
}

/// The biometric sensor this device has, without holding an `LAContext`.
nonisolated enum BiometryKind: Equatable, Sendable {
    case none, touchID, faceID, opticID

    init(_ type: LABiometryType) {
        switch type {
        case .faceID: self = .faceID
        case .touchID: self = .touchID
        case .opticID: self = .opticID
        default: self = .none
        }
    }

    /// Reads the sensor without prompting. `biometryType` is only set after a policy check.
    static var current: BiometryKind {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return BiometryKind(context.biometryType)
    }

    /// "Face ID", or nil when the device has no sensor.
    var name: String? {
        switch self {
        case .faceID: L10n.string("Face ID")
        case .touchID: L10n.string("Touch ID")
        case .opticID: L10n.string("Optic ID")
        case .none: nil
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock.fill"
        }
    }
}

/// Every status word Settings shows, as pure functions so tests can pin them.
/// Main-actor isolated (the module default) because it reads the app's model enums.
enum SettingsWords {
    // MARK: - Counts

    /// Resolves automatic grammar agreement into a plain string, for places that
    /// show markup literally (row values, dialog titles, `String` subtitles).
    static func inflected(_ resource: String.LocalizationValue) -> String {
        String(AttributedString(localized: resource).characters)
    }

    // MARK: - Account

    /// "LS" for "luke.smith@example.com", "L" for "luke@example.com".
    static func initials(for email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let words = local
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first)
        guard letters.isEmpty == false else { return "" }
        return String(letters).uppercased()
    }

    /// The host people recognize, or the stored text when it isn't a URL.
    static func serverHost(_ serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host, host.isEmpty == false else {
            return trimmed
        }
        if let port = components.port { return "\(host):\(String(port))" }
        return host
    }

    static func signOutTitle(pendingChanges: Int) -> String {
        pendingChanges > 0
            ? inflected("Sign Out and Delete ^[\(pendingChanges) Change](inflect: true)?")
            : L10n.string("Sign Out of Vaultwarden?")
    }

    /// Says what's lost on this device and what isn't touched on the server.
    static func signOutMessage(host: String, pendingChanges: Int, device: String) -> String {
        if pendingChanges > 0 {
            return inflected("Your vault, AutoFill data and settings are removed from this \(device), including ^[\(pendingChanges) change](inflect: true) that never reached the server. Your vault on \(host) isn’t affected.")
        }
        return L10n.format("Your vault, AutoFill data and settings are removed from this %@. Your vault on %@ isn’t affected.", device, host)
    }

    // MARK: - Security

    /// "Face ID", "Touch ID", "Optic ID", or "Master Password" when biometrics are off or absent.
    static func unlockMethodName(biometry: BiometryKind, biometricUnlock: Bool) -> String {
        guard biometricUnlock, let name = biometry.name else { return L10n.string("Master Password") }
        return name
    }

    /// The Security hero's line.
    static func unlockHeadline(biometry: BiometryKind, biometricUnlock: Bool) -> String {
        L10n.format("Unlock with %@", unlockMethodName(biometry: biometry, biometricUnlock: biometricUnlock))
    }

    static func minutes(_ timeout: VaultTimeout) -> Int? {
        guard let interval = timeout.timeInterval, interval > 0 else { return nil }
        return Int(interval / 60)
    }

    /// A row value: "Immediately", "5 Minutes", "Never".
    static func timeoutShort(_ timeout: VaultTimeout) -> String {
        switch timeout {
        case .immediately: return L10n.string("Immediately")
        case .never: return L10n.string("Never")
        default:
            let count = minutes(timeout) ?? 0
            return inflected("^[\(count) Minute](inflect: true)")
        }
    }

    /// A picker option that completes "Lock Vault": "Immediately", "After 5 Minutes", "Never".
    static func timeoutTitle(_ timeout: VaultTimeout) -> String {
        switch timeout {
        case .immediately: return L10n.string("Immediately")
        case .never: return L10n.string("Never")
        default:
            let count = minutes(timeout) ?? 0
            return inflected("After ^[\(count) Minute](inflect: true)")
        }
    }

    /// What the chosen timeout does, in the platform's terms.
    static func autoLockFooter(_ timeout: VaultTimeout, isMac: Bool) -> String {
        if isMac {
            switch timeout {
            case .immediately:
                return L10n.string("Vaultwarden locks when you switch to another app. Sleep and screen lock always lock it.")
            case .never:
                return L10n.string("Vaultwarden locks only when you lock it, or when your Mac sleeps or locks its screen.")
            default:
                let count = minutes(timeout) ?? 0
                return inflected("Vaultwarden locks after ^[\(count) minute](inflect: true) without using your Mac. Sleep and screen lock always lock it.")
            }
        }
        switch timeout {
        case .immediately:
            return L10n.string("Vaultwarden locks as soon as you leave it.")
        case .never:
            return L10n.string("Vaultwarden locks only when you lock it.")
        default:
            let count = minutes(timeout) ?? 0
            return inflected("Vaultwarden locks ^[\(count) minute](inflect: true) after you leave it.")
        }
    }

    /// The Unlock group's footer: what the current pair of switches means.
    static func unlockFooter(biometry: BiometryKind, biometricUnlock: Bool, passcodeFallback: Bool, isMac: Bool) -> String {
        let sensor = biometry.name ?? L10n.string("biometrics")
        guard biometricUnlock else {
            return L10n.format("Your master password unlocks the vault. AutoFill needs %@, so it’s unavailable while this is off.", sensor)
        }
        guard passcodeFallback else {
            return L10n.format("Only %@ or your master password can unlock the vault.", sensor)
        }
        return isMac
            ? L10n.format("If %@ doesn’t recognize you, your Mac login password works too. Your master password always works.", sensor)
            : L10n.format("If %@ doesn’t recognize you, your device passcode works too. Your master password always works.", sensor)
    }

    // MARK: - Sync

    enum SyncState: Equatable, Sendable {
        case syncing
        case needsSignIn
        case failed(String)
        case waiting(Int)
        case upToDate
    }

    /// Most urgent first: what's happening now, then what needs the person, then what's queued.
    static func syncState(isSyncing: Bool, needsSignIn: Bool, error: String?, pendingChanges: Int) -> SyncState {
        if isSyncing { return .syncing }
        if needsSignIn { return .needsSignIn }
        if let error, error.isEmpty == false { return .failed(error) }
        if pendingChanges > 0 { return .waiting(pendingChanges) }
        return .upToDate
    }

    /// "3 Changes Waiting", or "Up to Date".
    static func queueSummary(_ count: Int) -> String {
        count > 0
            ? inflected("^[\(count) Change](inflect: true) Waiting")
            : L10n.string("Up to Date")
    }

    /// The root row's value.
    static func syncShort(_ state: SyncState) -> String {
        switch state {
        case .syncing: L10n.string("Syncing…")
        case .needsSignIn: L10n.string("Sign In Required")
        case .failed: L10n.string("Couldn’t Sync")
        case .waiting(let count): queueSummary(count)
        case .upToDate: L10n.string("Up to Date")
        }
    }

    /// "Last synced Today at 9:41 AM".
    static func lastSyncedLine(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return L10n.format("Last synced %@", formatter.string(from: date))
    }

    /// The Sync hero's line.
    static func syncHeadline(_ state: SyncState, lastSynced: Date, usesOfflineCopy: Bool, locale: Locale = .current) -> String {
        switch state {
        case .syncing: return L10n.string("Syncing…")
        case .needsSignIn: return L10n.string("Sign in again to keep syncing")
        case .failed: return L10n.string("Couldn’t sync")
        case .waiting, .upToDate:
            if usesOfflineCopy { return L10n.string("Showing your offline copy") }
            return lastSyncedLine(lastSynced, locale: locale)
        }
    }

    static func syncTone(_ state: SyncState) -> StatusTone {
        switch state {
        case .needsSignIn: .attention
        case .failed: .failure
        case .syncing, .waiting, .upToDate: .plain
        }
    }

    // MARK: - AutoFill

    /// The AutoFill hero's line. `isEnabled` is nil until the system answers.
    static func autoFillHeadline(isEnabled: Bool?, isMac: Bool) -> String {
        switch isEnabled {
        case true?: L10n.string("On")
        case false?: isMac ? L10n.string("Turn On in System Settings") : L10n.string("Turn On in Settings")
        case nil: L10n.string("Fill passwords, passkeys and codes in apps and Safari.")
        }
    }

    static func autoFillShort(isEnabled: Bool?) -> String? {
        switch isEnabled {
        case true?: L10n.string("On")
        case false?: L10n.string("Off")
        case nil: nil
        }
    }

    static func autoFillTone(isEnabled: Bool?) -> StatusTone {
        isEnabled == false ? .attention : .plain
    }

    /// "245 Logins", for how many AutoFill can offer.
    static func loginCount(_ count: Int) -> String {
        inflected("^[\(count) Login](inflect: true)")
    }

    static func uriMatchFooter(_ type: AutoFillURIMatchType) -> String {
        switch type {
        case .baseDomain:
            L10n.string("Logins fill on any page of their domain, so a login for example.com also fills on accounts.example.com. A login’s own rule always wins.")
        case .host:
            L10n.string("Logins fill only on the same host and port they were saved for. A login’s own rule always wins.")
        case .startsWith:
            L10n.string("Logins fill on pages whose address starts with the saved one. A login’s own rule always wins.")
        case .exact:
            L10n.string("Logins fill only on the exact address they were saved for. A login’s own rule always wins.")
        case .regularExpression:
            L10n.string("Logins fill on pages whose address matches the saved pattern. A login’s own rule always wins.")
        case .never:
            L10n.string("Logins without their own rule aren’t suggested. A login’s own rule always wins.")
        }
    }

    // MARK: - Appearance

    static func themeTitle(_ theme: AppTheme) -> String {
        switch theme {
        case .system: L10n.string("Automatic")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    // MARK: - Data

    /// "Imported 12 items and 3 folders." with failures said once, after.
    static func importSummary(items: Int, folders: Int, failed: Int) -> String {
        let imported = inflected("Imported ^[\(items) item](inflect: true) and ^[\(folders) folder](inflect: true).")
        guard failed > 0 else { return imported }
        let failures = inflected("^[\(failed) item](inflect: true) couldn’t be imported.")
        return "\(imported) \(failures)"
    }

    // MARK: - SSH Agent

    static func sshHeadline(isEnabled: Bool, isRunning: Bool, startupFailed: Bool, enabledKeys: Int) -> String {
        guard isEnabled else { return L10n.string("Use SSH keys from your vault with ssh and Git.") }
        if startupFailed { return L10n.string("Couldn’t start the SSH agent") }
        guard isRunning else { return L10n.string("Sign in to start the SSH agent") }
        return enabledKeys > 0
            ? inflected("On · ^[\(enabledKeys) key](inflect: true) available")
            : L10n.string("On · no keys turned on yet")
    }

    static func sshTone(isEnabled: Bool, isRunning: Bool, startupFailed: Bool) -> StatusTone {
        guard isEnabled else { return .plain }
        if startupFailed { return .failure }
        return isRunning ? .plain : .attention
    }
}

/// Server addresses as people type them: the scheme is optional and becomes https.
nonisolated enum ServerAddress {
    enum Problem: Error, Equatable, Sendable {
        case empty, invalid, notHTTPS

        var message: String? {
            switch self {
            case .empty: nil
            case .invalid: L10n.string("Enter your server’s address, like vault.example.com.")
            case .notHTTPS: L10n.string("Vaultwarden needs an https:// address to keep your vault private.")
            }
        }
    }

    /// The https URL to connect to, or why the text can't be one. Only a missing
    /// scheme is added; anything else typed is kept, so saved sessions still match.
    static func normalized(_ input: String) -> Result<URL, Problem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .failure(.empty) }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return .failure(.invalid) }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        if scheme == "http" { return .failure(.notHTTPS) }
        guard scheme == "https" else { return .failure(.invalid) }
        components.scheme = "https"

        guard let host = components.host, isPlausibleHost(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    /// Whether a saved address will be accepted by the server connection, which requires https.
    static func isSecure(_ stored: String) -> Bool {
        URLComponents(string: stored.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() == "https"
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard host.isEmpty == false else { return false }
        // IPv6 literals arrive with or without brackets depending on the parser.
        if host.contains(":") { return true }
        if host.lowercased() == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ $0.isEmpty == false }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            label.unicodeScalars.allSatisfy { allowed.contains($0) }
                && label.hasPrefix("-") == false && label.hasSuffix("-") == false
        }
    }
}
