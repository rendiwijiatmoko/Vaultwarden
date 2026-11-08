import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Whether the system fills from Vaultwarden, how it matches websites, and what it
/// can offer. The page re-checks the system setting whenever the app comes back.
struct AutoFillSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isProviderEnabled: Bool?
    @State private var publishedCount = 0
    @State private var publishedAt: Date?
    @State private var isRequestingProvider = false
    @State private var settingsError: String?

    private var canManageVault: Bool { store.isAuthenticated && store.isLocked == false }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var settingsPath: Text {
        #if os(macOS)
        Text("System Settings ▸ General ▸ AutoFill & Passwords")
        #else
        Text("Settings ▸ General ▸ AutoFill & Passwords")
        #endif
    }

    var body: some View {
        Form {
            SettingsHero(
                Text("AutoFill & Passwords"),
                subtitle: heroLine,
                systemImage: "key.fill",
                tint: .green
            ) {
                #if os(macOS)
                if isProviderEnabled == false {
                    turnOnButton
                }
                #endif
            }

            if isProviderEnabled == false {
                Section {
                    #if os(macOS)
                    SettingsDetailRow(
                        title: Text("AutoFill Settings"),
                        detail: settingsPath
                    ) {
                        Button("Open…", action: openProviderSettings)
                    }
                    #else
                    turnOnButton
                    Button("Open AutoFill Settings", action: openProviderSettings)
                    #endif
                } footer: {
                    Text("Turn on Vaultwarden in \(settingsPath) to fill passwords, passkeys and codes in apps and Safari. This page updates on its own.")
                }
            }

            Section {
                #if os(macOS)
                SettingsDetailRow(
                    title: Text("Verification Codes"),
                    detail: Text("Save setup codes from websites straight into Vaultwarden.")
                ) {
                    Button("Choose…", action: openVerificationCodeSettings)
                }
                #else
                Button("Set Up Codes In…", action: openVerificationCodeSettings)
                #endif
            } footer: {
                if let settingsError {
                    StatusTone.failure.apply(to: Text(verbatim: settingsError))
                } else {
                    #if os(iOS)
                    Text("Choose Vaultwarden to save verification codes when a website shows a setup code.")
                    #endif
                }
            }

            if canManageVault {
                Section {
                    Picker("Match Websites", selection: defaultURIMatchDetection) {
                        ForEach(AutoFillURIMatchType.defaultChoices, id: \.self) { type in
                            Text(verbatim: type.title).tag(type)
                        }
                    }
                } header: {
                    Text("Matching")
                } footer: {
                    Text(verbatim: SettingsWords.uriMatchFooter(defaultURIMatchDetection.wrappedValue))
                        .contentTransition(.opacity)
                }

                Section {
                    LabeledContent("Logins") {
                        Text(publishedCount, format: .number)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(publishedCount)))
                    }
                    if let publishedAt {
                        LabeledContent("Updated") {
                            Text(publishedAt, format: .relative(presentation: .named))
                        }
                    }
                    #if os(macOS)
                    SettingsDetailRow(
                        title: Text("Update AutoFill"),
                        detail: Text("Syncs your vault, then refreshes what AutoFill can offer.")
                    ) {
                        updateButton
                    }
                    #else
                    updateButton
                    #endif
                } header: {
                    Text("Ready to Fill")
                } footer: {
                    Text("AutoFill keeps an encrypted list of your logins on this device, and asks you to unlock before it fills anything.")
                }
            } else {
                Section {
                } footer: {
                    Text("Unlock your vault to choose how AutoFill matches websites.")
                }
            }
        }
        #if os(macOS)
        .settingsPane()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshProviderStatus() }
        }
        #else
        .settingsPage(Text("AutoFill & Passwords"))
        #endif
        .animation(SettingsMotion.row, value: isProviderEnabled)
        .task { await refreshProviderStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshProviderStatus() }
        }
    }

    private var heroLine: Text {
        var line = SettingsWords.autoFillHeadline(isEnabled: isProviderEnabled, isMac: isMac)
        if isProviderEnabled == true, canManageVault, publishedCount > 0 {
            line = L10n.format("On · %@ ready to fill", SettingsWords.loginCount(publishedCount).lowercased())
        }
        return SettingsWords.autoFillTone(isEnabled: isProviderEnabled).apply(to: Text(verbatim: line))
    }

    private var turnOnButton: some View {
        Button {
            Task { await requestProvider() }
        } label: {
            if isRequestingProvider {
                ProgressView().controlSize(.small)
            } else {
                Text("Turn On AutoFill…")
            }
        }
        .disabled(isRequestingProvider)
    }

    private var updateButton: some View {
        Button {
            Task { await updateSharedCredentials() }
        } label: {
            if store.isSyncing {
                HStack(spacing: SettingsSpacing.standard) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
            } else {
                Text("Update Now")
            }
        }
        .disabled(store.isSyncing)
    }

    private var defaultURIMatchDetection: Binding<AutoFillURIMatchType> {
        Binding(
            get: { store.settings.defaultURIMatchDetection ?? .baseDomain },
            set: { store.settings.defaultURIMatchDetection = $0 }
        )
    }

    private func refreshProviderStatus() async {
        let state = await ASCredentialIdentityStore.shared.state()
        isProviderEnabled = state.isEnabled
        let defaults = UserDefaults(suiteName: AutoFillSharedVault.appGroupIdentifier)
        publishedCount = defaults?.integer(forKey: AutoFillSharedVault.publishedCountKey) ?? 0
        publishedAt = defaults?.object(forKey: AutoFillSharedVault.publishedAtKey) as? Date
    }

    private func requestProvider() async {
        isRequestingProvider = true
        _ = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
        isRequestingProvider = false
        await refreshProviderStatus()
    }

    private func updateSharedCredentials() async {
        guard canManageVault else { return }
        await store.sync()
        await refreshProviderStatus()
    }

    private func openProviderSettings() {
        settingsError = nil
        ASSettingsHelper.openCredentialProviderAppSettings { error in
            guard error != nil else { return }
            Task { @MainActor in
                settingsError = L10n.string("Settings couldn’t be opened. Open it yourself and go to General ▸ AutoFill & Passwords.")
            }
        }
    }

    private func openVerificationCodeSettings() {
        settingsError = nil
        ASSettingsHelper.openVerificationCodeAppSettings { error in
            guard error != nil else { return }
            Task { @MainActor in
                settingsError = L10n.string("Settings couldn’t be opened. Open it yourself and go to General ▸ AutoFill & Passwords.")
            }
        }
    }
}
