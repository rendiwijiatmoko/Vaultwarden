import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import vaultwardenApp

/// Renders key screens with demo data into PNGs for design review.
/// Runs only when `SNAPSHOT_DIR` is set (CI passes `TEST_RUNNER_SNAPSHOT_DIR`), so normal test runs skip it.
@MainActor
@Suite(.serialized)
struct UISnapshotTests {
    nonisolated private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test(.enabled(if: outputDirectory != nil))
    func renderScreens() async throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = await SnapshotDemo.makeStore()

        for screen in SnapshotDemo.screens(store: store) {
            for dark in [false, true] {
                try await SnapshotRenderer.render(
                    screen.view,
                    size: screen.size,
                    dark: dark,
                    to: directory.appending(path: "\(SnapshotRenderer.platform)-\(screen.name)-\(dark ? "dark" : "light").png")
                )
            }
        }
    }
}

struct SnapshotScreen {
    let name: String
    let size: CGSize
    let view: AnyView
}

@MainActor
enum SnapshotDemo {
    #if os(macOS)
    static let windowSize = CGSize(width: 1180, height: 780)
    static let settingsSize = CGSize(width: 680, height: 620)
    static let sheetSize = CGSize(width: 560, height: 640)
    #else
    static let windowSize = CGSize(width: 402, height: 874)
    static let settingsSize = windowSize
    static let sheetSize = windowSize
    #endif

    /// Signs in with the offline test service so secrets show as they do for a real
    /// unlocked account. If the keychain refuses (unsigned Mac runs), screens render signed out.
    static func makeStore() async -> AppStore {
        let defaults = UserDefaults(suiteName: "ui-snapshots-\(UUID().uuidString)")!
        let store = AppStore(vaultwardenService: LockTestService(), settingsDefaults: defaults)
        store.settings.syncOnOpen = false
        store.settings.backgroundRefresh = false
        try? await store.connect(
            serverURL: "https://vault.example.com",
            email: "alex.appleseed@icloud.com",
            masterPassword: "test"
        )
        store.settings.email = "alex.appleseed@icloud.com"
        store.settings.serverURL = "https://vault.example.com"
        store.folders = [VaultFolder(name: "Work"), VaultFolder(name: "Family"), VaultFolder(name: "Finance")]
        store.items = VaultSecurityAnalyzer.analyze(items)
        return store
    }

    static let items: [VaultItem] = {
        let now = Date()
        func login(_ name: String, _ user: String, _ uri: String, password: String = "kT7#pV2!xQ9m",
                   favorite: Bool = false, totp: String? = nil, folder: String? = nil, days: Double) -> VaultItem {
            var item = VaultItem(name: name, username: user, password: password, uri: uri,
                                 folder: folder, isFavorite: favorite, totpSecret: totp)
            item.updatedAt = now.addingTimeInterval(-days * 86_400)
            item.createdAt = item.updatedAt
            return item
        }
        var card = VaultItem(name: "Travel Card", type: .card)
        card.card = CardDetails(cardholderName: "Alex Appleseed", brand: "Visa", number: "4111111111114242",
                                expirationMonth: "08", expirationYear: "2029", securityCode: "123")
        var note = VaultItem(name: "Wi-Fi at Home", type: .secureNote)
        note.notes = "Network: Appleseed 5G"
        var identity = VaultItem(name: "Personal", type: .identity)
        identity.identity = IdentityDetails(firstName: "Alex", lastName: "Appleseed", email: "alex.appleseed@icloud.com")
        return [
            login("GitHub", "alexappleseed", "https://github.com", favorite: true,
                  totp: "JBSWY3DPEHPK3PXP", folder: "Work", days: 1),
            login("Apple Account", "alex.appleseed@icloud.com", "https://account.apple.com", favorite: true, days: 3),
            login("Amazon", "alex.appleseed@icloud.com", "https://www.amazon.com", password: "password1", days: 40),
            login("Bank of Example", "alexa", "https://bank.example.com", totp: "JBSWY3DPEHPK3PXQ",
                  folder: "Finance", days: 12),
            login("Figma", "alex@studio.example", "https://figma.com", folder: "Work", days: 6),
            login("Netflix", "family@example.com", "https://netflix.com", password: "password1", folder: "Family", days: 90),
            login("Notion", "alex@studio.example", "https://notion.so", folder: "Work", days: 2),
            login("Reddit", "appleseed_a", "https://reddit.com", days: 200),
            login("Slack", "alex@studio.example", "https://slack.com", folder: "Work", days: 8),
            login("Spotify", "alex.appleseed@icloud.com", "https://open.spotify.com", days: 30),
            card, note, identity
        ]
    }()

    static func screens(store: AppStore) -> [SnapshotScreen] {
        func screen<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) -> SnapshotScreen {
            SnapshotScreen(name: name, size: size, view: AnyView(view().environmentObject(store)))
        }
        var screens: [SnapshotScreen] = []
        let router = HomeQuickActionRouter()
        let github = store.items.first { $0.name == "GitHub" }!
        #if os(macOS)
        store.selectedFilter = .all
        store.selectedItemID = github.id
        #endif
        screens.append(screen("home", windowSize) { RootSplitView().environmentObject(router) })
        #if os(iOS)
        screens.append(screen("list", windowSize) {
            NavigationStack { VaultCollectionView(filter: .all, usesColumnSelection: false) }
        })
        screens.append(screen("detail", windowSize) { NavigationStack { VaultItemDetailView(itemID: github.id) } })
        screens.append(screen("codes", windowSize) {
            NavigationStack { VaultCollectionView(filter: .category(.codes), usesColumnSelection: false) }
        })
        #endif
        screens.append(screen("security", windowSize) {
            NavigationStack { VaultCollectionView(filter: .category(.security), usesColumnSelection: false) }
        })
        screens.append(screen("editor", sheetSize) { AddEditVaultItemView(existingItem: github) })
        #if os(macOS)
        let agent = MacSSHAgent(store: store, socketPath: NSTemporaryDirectory() + "snapshot-agent.sock")
        screens.append(screen("settings", settingsSize) { MacSettingsView().environmentObject(agent) })
        #else
        screens.append(screen("settings", settingsSize) { SettingsView() })
        #endif
        screens.append(screen("icloud-backup", settingsSize) { NavigationStack { ICloudBackupSettingsView() } })
        screens.append(screen("generator", sheetSize) { GeneratorView() })
        screens.append(screen("onboarding", windowSize) { OnboardingView(onComplete: {}) })
        return screens
    }
}

@MainActor
enum SnapshotRenderer {
    #if os(macOS)
    static let platform = "mac"

    static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) async throws {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        let target = window.contentView?.superview ?? window.contentView!
        target.layoutSubtreeIfNeeded()
        guard let representation = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        window.close()
    }
    #else
    static let platform = "iphone"

    static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: url)
        window.isHidden = true
        window.rootViewController = nil
    }
    #endif
}
