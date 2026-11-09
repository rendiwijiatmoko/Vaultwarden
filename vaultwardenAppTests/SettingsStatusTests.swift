import Foundation
import Testing
@testable import vaultwardenApp

@MainActor
struct SettingsWordsTests {
    // MARK: - Auto-Lock

    @Test(arguments: [
        (VaultTimeout.immediately, "Immediately"),
        (.oneMinute, "1 Minute"),
        (.fiveMinutes, "5 Minutes"),
        (.tenMinutes, "10 Minutes"),
        (.fifteenMinutes, "15 Minutes"),
        (.never, "Never"),
    ])
    func timeoutRowValueSaysHowLong(timeout: VaultTimeout, expected: String) {
        #expect(SettingsWords.timeoutShort(timeout) == expected)
    }

    @Test(arguments: [
        (VaultTimeout.immediately, "Immediately"),
        (.oneMinute, "After 1 Minute"),
        (.fiveMinutes, "After 5 Minutes"),
        (.never, "Never"),
    ])
    func timeoutOptionsCompleteLockVault(timeout: VaultTimeout, expected: String) {
        #expect(SettingsWords.timeoutTitle(timeout) == expected)
    }

    @Test func autoLockFooterAgreesWithTheCount() {
        #expect(SettingsWords.autoLockFooter(.oneMinute, isMac: false) == "Vaultwarden locks 1 minute after you leave it.")
        #expect(SettingsWords.autoLockFooter(.fifteenMinutes, isMac: false) == "Vaultwarden locks 15 minutes after you leave it.")
        #expect(SettingsWords.autoLockFooter(.fiveMinutes, isMac: true).hasPrefix("Vaultwarden locks after 5 minutes without using your Mac."))
    }

    @Test func autoLockFooterNeverLeavesMarkup() {
        for timeout in VaultTimeout.allCases {
            for isMac in [true, false] {
                let footer = SettingsWords.autoLockFooter(timeout, isMac: isMac)
                #expect(footer.contains("^[") == false, "Unresolved inflection in \(footer)")
            }
        }
    }

    // MARK: - Unlock

    @Test(arguments: [
        (BiometryKind.faceID, "Face ID"),
        (.touchID, "Touch ID"),
        (.opticID, "Optic ID"),
    ])
    func unlockMethodNamesTheSensor(biometry: BiometryKind, expected: String) {
        #expect(SettingsWords.unlockMethodName(biometry: biometry, biometricUnlock: true) == expected)
    }

    @Test(arguments: [BiometryKind.none, .faceID, .touchID, .opticID])
    func unlockMethodIsMasterPasswordWhenBiometricsAreOff(biometry: BiometryKind) {
        #expect(SettingsWords.unlockMethodName(biometry: biometry, biometricUnlock: false) == "Master Password")
    }

    @Test func unlockMethodIsMasterPasswordWithoutASensor() {
        #expect(SettingsWords.unlockMethodName(biometry: .none, biometricUnlock: true) == "Master Password")
        #expect(SettingsWords.unlockHeadline(biometry: .none, biometricUnlock: true) == "Unlock with Master Password")
        #expect(SettingsWords.unlockHeadline(biometry: .faceID, biometricUnlock: true) == "Unlock with Face ID")
    }

    @Test func unlockFooterFollowsBothSwitches() {
        let off = SettingsWords.unlockFooter(biometry: .faceID, biometricUnlock: false, passcodeFallback: false, isMac: false)
        let strict = SettingsWords.unlockFooter(biometry: .faceID, biometricUnlock: true, passcodeFallback: false, isMac: false)
        let fallback = SettingsWords.unlockFooter(biometry: .touchID, biometricUnlock: true, passcodeFallback: true, isMac: true)
        #expect(off.contains("AutoFill needs Face ID"))
        #expect(strict == "Only Face ID or your master password can unlock the vault.")
        #expect(fallback.contains("Mac login password"))
    }

    // MARK: - Sync

    @Test(arguments: [
        (0, "Up to Date"),
        (1, "1 Change Waiting"),
        (3, "3 Changes Waiting"),
    ])
    func queueSummaryCountsChanges(count: Int, expected: String) {
        #expect(SettingsWords.queueSummary(count) == expected)
    }

    @Test func syncStateReportsTheMostUrgentFirst() {
        #expect(SettingsWords.syncState(isSyncing: true, needsSignIn: true, error: "x", pendingChanges: 2) == .syncing)
        #expect(SettingsWords.syncState(isSyncing: false, needsSignIn: true, error: "x", pendingChanges: 2) == .needsSignIn)
        #expect(SettingsWords.syncState(isSyncing: false, needsSignIn: false, error: "x", pendingChanges: 2) == .failed("x"))
        #expect(SettingsWords.syncState(isSyncing: false, needsSignIn: false, error: nil, pendingChanges: 2) == .waiting(2))
        #expect(SettingsWords.syncState(isSyncing: false, needsSignIn: false, error: "", pendingChanges: 0) == .upToDate)
    }

    @Test func syncRowValueIsShortAndTrue() {
        #expect(SettingsWords.syncShort(.syncing) == "Syncing…")
        #expect(SettingsWords.syncShort(.needsSignIn) == "Sign In Required")
        #expect(SettingsWords.syncShort(.failed("Offline")) == "Couldn’t Sync")
        #expect(SettingsWords.syncShort(.waiting(2)) == "2 Changes Waiting")
        #expect(SettingsWords.syncShort(.upToDate) == "Up to Date")
    }

    @Test func syncHeadlineSaysWhenItLastSynced() {
        let locale = Locale(identifier: "en_US")
        let line = SettingsWords.syncHeadline(.upToDate, lastSynced: .now, usesOfflineCopy: false, locale: locale)
        #expect(line.hasPrefix("Last synced Today"), "Got \(line)")
    }

    @Test func syncHeadlineStatesProblemsWithoutTheDate() {
        #expect(SettingsWords.syncHeadline(.failed("Offline"), lastSynced: .now, usesOfflineCopy: false) == "Couldn’t sync")
        #expect(SettingsWords.syncHeadline(.waiting(1), lastSynced: .now, usesOfflineCopy: true) == "Showing your offline copy")
        #expect(SettingsWords.syncTone(.failed("Offline")) == .failure)
        #expect(SettingsWords.syncTone(.needsSignIn) == .attention)
        #expect(SettingsWords.syncTone(.upToDate) == .plain)
    }

    // MARK: - AutoFill

    @Test func autoFillStatusAsksForActionOnlyWhenOff() {
        #expect(SettingsWords.autoFillHeadline(isEnabled: true, isMac: false) == "On")
        #expect(SettingsWords.autoFillHeadline(isEnabled: false, isMac: false) == "Turn On in Settings")
        #expect(SettingsWords.autoFillHeadline(isEnabled: false, isMac: true) == "Turn On in System Settings")
        #expect(SettingsWords.autoFillShort(isEnabled: nil) == nil)
        #expect(SettingsWords.autoFillTone(isEnabled: false) == .attention)
        #expect(SettingsWords.autoFillTone(isEnabled: true) == .plain)
    }

    @Test(arguments: [(1, "1 Login"), (245, "245 Logins")])
    func loginCountAgrees(count: Int, expected: String) {
        #expect(SettingsWords.loginCount(count) == expected)
    }

    // MARK: - Account

    @Test(arguments: [
        ("luke.smith@example.com", "LS"),
        ("luke@example.com", "L"),
        ("a-b_c@example.com", "AB"),
        ("123@example.com", ""),
        ("", ""),
    ])
    func initialsComeFromTheAddress(email: String, expected: String) {
        #expect(SettingsWords.initials(for: email) == expected)
    }

    @Test func serverHostDropsTheScheme() {
        #expect(SettingsWords.serverHost("https://vault.example.com") == "vault.example.com")
        #expect(SettingsWords.serverHost("https://vault.example.com:8443/") == "vault.example.com:8443")
        #expect(SettingsWords.serverHost("not a url") == "not a url")
    }

    @Test func signOutCountsWhatIsLost() {
        #expect(SettingsWords.signOutTitle(pendingChanges: 0) == "Sign Out of Vaultwarden?")
        #expect(SettingsWords.signOutTitle(pendingChanges: 1) == "Sign Out and Delete 1 Change?")
        #expect(SettingsWords.signOutTitle(pendingChanges: 4) == "Sign Out and Delete 4 Changes?")
        let message = SettingsWords.signOutMessage(host: "vault.example.com", pendingChanges: 2, device: "iPhone")
        #expect(message.contains("2 changes that never reached the server"))
        #expect(message.contains("vault.example.com"))
        #expect(message.contains("^[") == false)
    }

    // MARK: - Data

    @Test func importSummaryCountsAndMentionsFailuresOnce() {
        #expect(SettingsWords.importSummary(items: 1, folders: 1, failed: 0) == "Imported 1 item and 1 folder.")
        #expect(SettingsWords.importSummary(items: 12, folders: 3, failed: 2) == "Imported 12 items and 3 folders. 2 items couldn’t be imported.")
    }

    // MARK: - Appearance and SSH

    @Test func systemThemeReadsAsAutomatic() {
        #expect(SettingsWords.themeTitle(.system) == "Automatic")
        #expect(SettingsWords.themeTitle(.dark) == "Dark")
    }

    @Test func sshHeadlineReportsKeys() {
        #expect(SettingsWords.sshHeadline(isEnabled: true, isRunning: true, startupFailed: false, enabledKeys: 1) == "On · 1 key available")
        #expect(SettingsWords.sshHeadline(isEnabled: true, isRunning: true, startupFailed: false, enabledKeys: 2) == "On · 2 keys available")
        #expect(SettingsWords.sshTone(isEnabled: true, isRunning: false, startupFailed: true) == .failure)
        #expect(SettingsWords.sshTone(isEnabled: false, isRunning: false, startupFailed: true) == .plain)
    }
}

struct ServerAddressTests {
    @Test(arguments: [
        ("vault.example.com", "https://vault.example.com"),
        ("  vault.example.com  ", "https://vault.example.com"),
        ("HTTPS://vault.example.com", "https://vault.example.com"),
        ("https://vault.example.com/", "https://vault.example.com/"),
        ("vault.example.com:8443/bitwarden", "https://vault.example.com:8443/bitwarden"),
        ("localhost:8080", "https://localhost:8080"),
        ("192.168.1.20", "https://192.168.1.20"),
    ])
    func addsHTTPSAndKeepsWhatWasTyped(input: String, expected: String) throws {
        let url = try ServerAddress.normalized(input).get()
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: ["http://vault.example.com", "HTTP://vault.example.com"])
    func refusesPlainHTTP(input: String) {
        #expect(throws: ServerAddress.Problem.notHTTPS) {
            try ServerAddress.normalized(input).get()
        }
    }

    @Test(arguments: [
        "vault",
        "vault example.com",
        "ftp://vault.example.com",
        "https://user:pass@vault.example.com",
        "https://vault.example.com?x=1",
        "vault..example.com",
        "-vault.example.com",
        "https://",
    ])
    func refusesWhatCantBeAServer(input: String) {
        #expect(throws: ServerAddress.Problem.invalid) {
            try ServerAddress.normalized(input).get()
        }
    }

    @Test func emptyIsNotAnErrorToShow() {
        #expect(throws: ServerAddress.Problem.empty) {
            try ServerAddress.normalized("   ").get()
        }
        #expect(ServerAddress.Problem.empty.message == nil)
    }

    @Test func storedAddressesAreCheckedForHTTPS() {
        #expect(ServerAddress.isSecure("https://vault.example.com"))
        #expect(ServerAddress.isSecure("http://vault.example.com") == false)
    }
}
