import Foundation

/// Gives App Intents the app's single store and a way to bring the vault
/// window forward.
///
/// Intents run in the app's own process. `VaultwardenApp.init` configures this
/// before any intent performs, including when the system launches the app in
/// the background just to run one. Intents never read vault contents through
/// it; they only route, lock or sync.
@MainActor
enum AppIntentEnvironment {
    private(set) static var store: AppStore?

    /// The Mac keeps running in the menu bar with its vault window closed, so
    /// an intent that opens the app must also reopen that window.
    static var showVault: (() -> Void)?

    static func configure(store: AppStore) {
        self.store = store
    }

    /// Queues the action for the unlocked vault and brings the vault forward.
    /// A locked vault shows its lock screen first; the action waits.
    static func open(_ action: HomeQuickAction?, router: HomeQuickActionRouter = .shared) {
        if let action { router.enqueue(action) }
        showVault?()
    }
}
