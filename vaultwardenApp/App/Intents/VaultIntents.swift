import AppIntents
import Foundation

// None of these intents return or speak vault contents. The ones that open the
// app only route to a screen, which still sits behind the lock screen.

nonisolated struct OpenVaultIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Vault" }
    static var description: IntentDescription { IntentDescription("Opens your vault.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentEnvironment.open(nil)
        return .result()
    }
}

nonisolated struct SearchVaultIntent: AppIntent {
    static var title: LocalizedStringResource { "Search Vault" }
    static var description: IntentDescription { IntentDescription("Opens your vault with search ready.") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Search Text")
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Search vault for \(\.$query)")
    }

    /// Pure so tests can check routing without the App Intents runtime.
    static func action(for query: String?) -> HomeQuickAction {
        .search(query: query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentEnvironment.open(Self.action(for: query))
        return .result()
    }
}

nonisolated struct ShowVerificationCodesIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Verification Codes" }
    static var description: IntentDescription { IntentDescription("Opens your verification codes.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentEnvironment.open(.verificationCodes)
        return .result()
    }
}

nonisolated struct NewPasswordIntent: AppIntent {
    static var title: LocalizedStringResource { "New Password" }
    static var description: IntentDescription { IntentDescription("Opens a new login in your vault.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentEnvironment.open(.newPassword)
        return .result()
    }
}

nonisolated struct LockVaultIntent: AppIntent {
    static var title: LocalizedStringResource { "Lock Vault" }
    static var description: IntentDescription { IntentDescription("Locks your vault right away.") }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A process the system just launched has no store yet or a locked
        // one; either way the vault is already locked.
        guard let store = AppIntentEnvironment.store else {
            return .result(dialog: "Vault locked.")
        }
        guard store.isAuthenticated else { throw VaultIntentError.signedOut }
        if !store.isLocked {
            store.lock(requestAutomaticUnlock: false)
        }
        return .result(dialog: "Vault locked.")
    }
}

nonisolated struct SyncVaultIntent: AppIntent {
    static var title: LocalizedStringResource { "Sync Vault" }
    static var description: IntentDescription { IntentDescription("Syncs your vault with your server.") }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = AppIntentEnvironment.store, store.isAuthenticated else {
            throw VaultIntentError.signedOut
        }
        // Syncing decrypts the vault, which needs the person to unlock it.
        guard !store.isLocked else { throw VaultIntentError.locked }
        await store.sync()
        guard store.lastSyncError == nil else { throw VaultIntentError.syncFailed }
        return .result(dialog: "Vault synced.")
    }
}

nonisolated enum VaultIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case signedOut
    case locked
    case syncFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Vaultwarden first."
        case .locked: "Unlock Vaultwarden, then try again."
        case .syncFailed: "Sync didn’t finish. Open Vaultwarden to see why."
        }
    }
}
