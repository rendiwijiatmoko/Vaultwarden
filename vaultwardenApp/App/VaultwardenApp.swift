import SwiftUI

@main
struct VaultwardenApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(VaultwardenApplicationDelegate.self) private var applicationDelegate
    #else
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    #endif
    @StateObject private var store: AppStore
    @StateObject private var quickActions: HomeQuickActionRouter
    #if os(macOS)
    @StateObject private var sshAgent: MacSSHAgent
    @StateObject private var menuBar: MacMenuBarController
    #endif

    init() {
        #if DEBUG
        // Reset once at launch instead of overriding AppStorage through the
        // argument domain, which prevents onboarding completion from persisting.
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
            UserDefaults.standard.removeObject(forKey: "hasRequestedAutoFillSetup")
        }
        #endif
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _quickActions = StateObject(wrappedValue: .shared)
        // Before any intent can perform, including background launches.
        AppIntentEnvironment.configure(store: store)
        #if os(macOS)
        let agent = MacSSHAgent(store: store)
        let menuBar = MacMenuBarController(store: store, agent: agent)
        _sshAgent = StateObject(wrappedValue: agent)
        _menuBar = StateObject(wrappedValue: menuBar)
        AppIntentEnvironment.showVault = { [weak menuBar] in menuBar?.openVault() }
        MacVaultLifecycle.start(store: store)
        #endif
        BackgroundSyncManager.register { await store.performBackgroundRefresh() }
    }

    var body: some Scene {
        #if os(macOS)
        // A single vault window keeps all commands and lock state in one place.
        Window("Vaultwarden", id: MacWindowID.vault) {
            ContentView(store: store)
                .modifier(SSHAgentPresentation())
                .environmentObject(quickActions)
                .environmentObject(store)
                .environmentObject(sshAgent)
                .environmentObject(menuBar)
                .background(MacWindowRegistration(dockVisibility: menuBar.dockVisibility))
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            VaultCommands(store: store, quickActions: quickActions)
        }

        // Generating a password needs no vault, so this window works while
        // locked. History and Save to Vault appear only while unlocked.
        Window("Generator", id: MacWindowID.generator) {
            GeneratorView(presentation: .window)
                .environmentObject(store)
                .preferredColorScheme(store.settings.theme.colorScheme)
                .background(MacWindowRegistration(dockVisibility: menuBar.dockVisibility))
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            MacSettingsView()
                .environmentObject(store)
                .environmentObject(sshAgent)
                .background(MacWindowRegistration(dockVisibility: menuBar.dockVisibility))
        }
        #else
        WindowGroup {
            ContentView(store: store)
                .environmentObject(quickActions)
        }
        #endif
    }
}

private extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

#if os(macOS)
enum MacWindowID {
    static let vault = "vault"
    static let generator = "generator"
}

/// The menu bar's home for every vault action, with the standard shortcuts.
/// Vault actions are disabled while signed out or locked; they never open a
/// locked vault's contents.
private struct VaultCommands: Commands {
    @ObservedObject var store: AppStore
    let quickActions: HomeQuickActionRouter
    @Environment(\.openWindow) private var openWindow

    private static let projectURL = URL(string: "https://github.com/slukedev/vaultwarden-apple")

    private var isVaultUnavailable: Bool { !store.isAuthenticated || store.isLocked }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Password") { open(.newPassword) }
                .keyboardShortcut("n")
                .disabled(isVaultUnavailable)
        }

        CommandGroup(before: .textEditing) {
            Button("Find") { open(.search(query: "")) }
                .keyboardShortcut("f")
                .disabled(isVaultUnavailable)
            Divider()
        }

        CommandMenu("Vault") {
            Button("Verification Codes") { open(.verificationCodes) }
                .keyboardShortcut("2")
                .disabled(isVaultUnavailable)
            Button("Generator") { openWindow(id: MacWindowID.generator) }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
            Button("Sync Now") { Task { await store.sync() } }
                .keyboardShortcut("r")
                .disabled(isVaultUnavailable || store.isSyncing)
            Button("Lock Vault") { store.lock(requestAutomaticUnlock: false) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(isVaultUnavailable)
        }

        SidebarCommands()

        CommandGroup(replacing: .help) {
            if let projectURL = Self.projectURL {
                Link("Vaultwarden on GitHub", destination: projectURL)
            }
        }
    }

    /// Brings the vault window forward first, since it may be closed while the
    /// app keeps running in the menu bar.
    private func open(_ action: HomeQuickAction) {
        openWindow(id: MacWindowID.vault)
        quickActions.enqueue(action)
    }
}
#endif
