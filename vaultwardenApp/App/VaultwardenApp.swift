import SwiftUI

@main
struct VaultwardenApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(VaultwardenApplicationDelegate.self) private var applicationDelegate
    #endif
    @StateObject private var store: AppStore
    @StateObject private var quickActions: HomeQuickActionRouter

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
        BackgroundSyncManager.register { await store.performBackgroundRefresh() }
    }

    var body: some Scene {
        #if os(macOS)
        // A single vault window keeps all commands and lock state in one place.
        Window("Vaultwarden", id: "vault") {
            ContentView(store: store)
                .environmentObject(quickActions)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Password") { quickActions.enqueue(.newPassword) }
                    .keyboardShortcut("n")
                    .disabled(!store.isAuthenticated || store.isLocked)
            }
            CommandMenu("Vault") {
                Button("Search") { quickActions.enqueue(.search) }
                    .keyboardShortcut("f")
                    .disabled(!store.isAuthenticated || store.isLocked)
                Button("Verification Codes") { quickActions.enqueue(.verificationCodes) }
                    .keyboardShortcut("2")
                    .disabled(!store.isAuthenticated || store.isLocked)
                Divider()
                Button("Sync Now") { Task { await store.sync() } }
                    .keyboardShortcut("r")
                    .disabled(!store.isAuthenticated || store.isLocked || store.isSyncing)
                Button("Lock Vault") { store.lock(requestAutomaticUnlock: false) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!store.isAuthenticated || store.isLocked)
            }
            SidebarCommands()
        }
        Settings {
            MacSettingsView()
                .environmentObject(store)
        }
        #else
        WindowGroup {
            ContentView(store: store)
                .environmentObject(quickActions)
        }
        #endif
    }
}
