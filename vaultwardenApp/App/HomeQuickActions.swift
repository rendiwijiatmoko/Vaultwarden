import Combine
#if os(iOS)
import UIKit
#endif

/// A place in the app that something outside the vault window asked for:
/// a Home Screen quick action, an App Intent or a Mac menu command.
nonisolated enum HomeQuickAction: Equatable, Sendable {
    case newPassword
    /// An empty query opens search with the field focused.
    case search(query: String)
    case verificationCodes
    case generator

    /// `UIApplicationShortcutItemType` values in Info.plist.
    nonisolated enum ShortcutType {
        static let newPassword = "xyz.0xmwehehe.vaultwardenApp.quickAction.newPassword"
        static let search = "xyz.0xmwehehe.vaultwardenApp.quickAction.search"
        static let verificationCodes = "xyz.0xmwehehe.vaultwardenApp.quickAction.verificationCodes"
        static let generator = "xyz.0xmwehehe.vaultwardenApp.quickAction.generator"
    }

    init?(shortcutType: String) {
        switch shortcutType {
        case ShortcutType.newPassword: self = .newPassword
        case ShortcutType.search: self = .search(query: "")
        case ShortcutType.verificationCodes: self = .verificationCodes
        case ShortcutType.generator: self = .generator
        default: return nil
        }
    }

    var shortcutType: String {
        switch self {
        case .newPassword: ShortcutType.newPassword
        case .search: ShortcutType.search
        case .verificationCodes: ShortcutType.verificationCodes
        case .generator: ShortcutType.generator
        }
    }
}

/// Bridges UIKit's scene callbacks, App Intents and Mac commands into the
/// SwiftUI view hierarchy.
///
/// The most recent action stays pending until the authenticated, unlocked root
/// view consumes it. This means launching from an action never bypasses the
/// vault's normal sign-in or lock screen.
@MainActor
final class HomeQuickActionRouter: ObservableObject {
    static let shared = HomeQuickActionRouter()

    @Published private(set) var pendingAction: HomeQuickAction?

    /// Internal so tests can use their own router instead of the shared one.
    init() {}

    func enqueue(_ action: HomeQuickAction) {
        pendingAction = action
    }

    @discardableResult
    func enqueue(shortcutType: String) -> Bool {
        guard let action = HomeQuickAction(shortcutType: shortcutType) else { return false }
        enqueue(action)
        return true
    }

    #if os(iOS)
    @discardableResult
    func enqueue(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        enqueue(shortcutType: shortcutItem.type)
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
