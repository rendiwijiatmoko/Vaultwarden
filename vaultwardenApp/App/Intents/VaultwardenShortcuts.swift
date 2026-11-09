import AppIntents

/// Registered automatically, so these appear in Spotlight, Siri and the
/// Shortcuts app without any setup. Every phrase names the app.
nonisolated struct VaultwardenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GeneratePasswordIntent(),
            phrases: [
                "Generate a password in \(.applicationName)",
                "Generate a password with \(.applicationName)",
                "Make a strong password with \(.applicationName)",
                "Suggest a password in \(.applicationName)"
            ],
            shortTitle: "Generate Password",
            systemImageName: "wand.and.sparkles"
        )
        AppShortcut(
            intent: SearchVaultIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName) vault",
                "Find a password in \(.applicationName)"
            ],
            shortTitle: "Search Vault",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ShowVerificationCodesIntent(),
            phrases: [
                "Show verification codes in \(.applicationName)",
                "Show my \(.applicationName) codes",
                "Open \(.applicationName) verification codes"
            ],
            shortTitle: "Verification Codes",
            systemImageName: "lock.rotation"
        )
        AppShortcut(
            intent: NewPasswordIntent(),
            phrases: [
                "Add a password to \(.applicationName)",
                "New password in \(.applicationName)",
                "Save a new login in \(.applicationName)"
            ],
            shortTitle: "New Password",
            systemImageName: "key.fill"
        )
        AppShortcut(
            intent: LockVaultIntent(),
            phrases: [
                "Lock \(.applicationName)",
                "Lock my \(.applicationName) vault"
            ],
            shortTitle: "Lock Vault",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: SyncVaultIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Sync my \(.applicationName) vault"
            ],
            shortTitle: "Sync Vault",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: OpenVaultIntent(),
            phrases: [
                "Open my \(.applicationName) vault",
                "Show my passwords in \(.applicationName)"
            ],
            shortTitle: "Open Vault",
            systemImageName: "lock.shield"
        )
    }
}
