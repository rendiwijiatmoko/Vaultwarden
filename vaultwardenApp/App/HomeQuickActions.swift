import Combine
#if os(iOS)
import UIKit
#endif

/// Actions exposed from the app icon on the Home Screen.
enum HomeQuickAction: String, Equatable {
    case newPassword = "xyz.0xmwehehe.vaultwardenApp.quickAction.newPassword"
    case search = "xyz.0xmwehehe.vaultwardenApp.quickAction.search"
    case verificationCodes = "xyz.0xmwehehe.vaultwardenApp.quickAction.verificationCodes"
}

/// Bridges UIKit's scene callbacks into the SwiftUI view hierarchy.
///
/// The most recent action stays pending until the authenticated, unlocked root
/// view consumes it. This means launching from an action never bypasses the
/// vault's normal sign-in or lock screen.
@MainActor
final class HomeQuickActionRouter: ObservableObject {
    static let shared = HomeQuickActionRouter()

    @Published private(set) var pendingAction: HomeQuickAction?

    private init() {}

    func enqueue(_ action: HomeQuickAction) {
        pendingAction = action
    }

    @discardableResult
    func enqueue(rawValue: String) -> Bool {
        guard let action = HomeQuickAction(rawValue: rawValue) else { return false }
        enqueue(action)
        return true
    }

    #if os(iOS)
    @discardableResult
    func enqueue(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = HomeQuickAction(rawValue: shortcutItem.type) else { return false }
        pendingAction = action
        return true
    }

    #endif

    func consume(_ action: HomeQuickAction) {
        guard pendingAction == action else { return }
        pendingAction = nil
    }
}

#if os(iOS)
/// SwiftUI apps don't install a scene delegate by default. A custom delegate
/// is required because UIKit delivers warm-launch quick actions to the active
/// window scene rather than to the application delegate.
final class VaultwardenSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            HomeQuickActionRouter.shared.enqueue(shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HomeQuickActionRouter.shared.enqueue(shortcutItem))
    }
}

final class VaultwardenApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = VaultwardenSceneDelegate.self
        return configuration
    }
}

#endif
