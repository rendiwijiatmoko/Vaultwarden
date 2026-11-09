import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// The Mac Settings window's panes. Stored, so Settings reopens where it was left and
/// a feature can open it on its own pane (write the key, then `openSettings()`).
enum SettingsPane: String {
    case general, account, security, autoFill, sync, backup, data, sshAgent, about

    static let storageKey = "settings.pane"

    var requiresUnlockedVault: Bool {
        switch self {
        case .security, .sync, .backup, .data: true
        case .general, .account, .autoFill, .sshAgent, .about: false
        }
    }
}

/// Shown by the native Settings scene and the standard Command-comma shortcut.
struct MacSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.account

    private var canManageVault: Bool {
        store.isAuthenticated && store.isLocked == false
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: SettingsPane.general) {
                AppearanceSettingsView()
            }
            Tab("Account", systemImage: "person.crop.circle", value: SettingsPane.account) {
                if canManageVault {
                    AccountSettingsView()
                } else {
                    AccountAccessPane()
                }
            }
            if canManageVault {
                Tab("Security", systemImage: "lock", value: SettingsPane.security) {
                    SecuritySettingsView()
                }
            }
            Tab("AutoFill", systemImage: "key", value: SettingsPane.autoFill) {
                AutoFillSettingsView()
            }
            if canManageVault {
                Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: SettingsPane.sync) {
                    SyncSettingsView()
                }
                Tab("Backup", systemImage: "icloud", value: SettingsPane.backup) {
                    ICloudBackupSettingsView()
                        .settingsPane()
                }
                Tab("Data", systemImage: "externaldrive", value: SettingsPane.data) {
                    DataSettingsView()
                }
            }
            Tab("SSH Agent", systemImage: "terminal", value: SettingsPane.sshAgent) {
                SSHAgentSettingsView()
            }
            Tab("About", systemImage: "info.circle", value: SettingsPane.about) {
                AboutSettingsView()
            }
        }
        .preferredColorScheme(preferredColorScheme)
        // A pane that needs the unlocked vault falls back to Account when it locks.
        .onChange(of: canManageVault, initial: true) { _, canManage in
            if canManage == false && pane.requiresUnlockedVault {
                pane = .account
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The Account pane while the vault is locked or nobody is signed in.
private struct AccountAccessPane: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            if store.isAuthenticated {
                SettingsHero(
                    title: Text(verbatim: store.settings.email),
                    subtitle: Text("Vault locked · unlock it to change account, security, sync and data settings.")
                ) {
                    AccountAvatar(email: store.settings.email, baseSide: SettingsHero<AccountAvatar, EmptyView>.tileSide)
                } accessory: {
                    Button("Open Vault") { openWindow(id: "vault") }
                }
            } else {
                SettingsHero(
                    Text("Not Signed In"),
                    subtitle: Text("Sign in to your Vaultwarden server to use your vault on this Mac."),
                    systemImage: "person.crop.circle.fill",
                    tint: .gray
                ) {
                    Button("Sign In…") { openWindow(id: "vault") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .settingsPane()
    }
}
#endif

/// iPhone and iPad Settings: a sheet with the account at the top, then rows that say
/// where each page stands, as the Settings app does.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAutoFillEnabled: Bool?
    @State private var biometry = BiometryKind.current

    private var syncState: SettingsWords.SyncState {
        SettingsWords.syncState(
            isSyncing: store.isSyncing,
            needsSignIn: store.sessionNeedsSignIn,
            error: store.lastSyncError,
            pendingChanges: store.pendingMutationCount
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        AccountSummaryRow(
                            email: store.settings.email,
                            host: SettingsWords.serverHost(store.settings.serverURL),
                            needsSignIn: store.sessionNeedsSignIn
                        )
                    }
                }

                Section {
                    NavigationLink {
                        AutoFillSettingsView()
                    } label: {
                        SettingsRowLabel(
                            Text("AutoFill & Passwords"),
                            systemImage: "key.fill",
                            tint: .green,
                            value: SettingsWords.autoFillShort(isEnabled: isAutoFillEnabled).map { Text(verbatim: $0) }
                        )
                    }
                    NavigationLink {
                        SecuritySettingsView()
                    } label: {
                        SettingsRowLabel(
                            Text("Security"),
                            systemImage: store.settings.biometricUnlock ? biometry.systemImage : "lock.fill",
                            tint: .red,
                            value: Text(verbatim: SettingsWords.timeoutShort(store.settings.vaultTimeout))
                        )
                    }
                    NavigationLink {
                        PendingLoginRequestsView()
                    } label: {
                        SettingsRowLabel(Text("Login Requests"), systemImage: "checkmark.shield.fill", tint: .blue)
                    }
                } header: {
                    Text("Access")
                }

                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        SettingsRowLabel(
                            Text("Sync"),
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: .cyan,
                            value: SettingsWords.syncTone(syncState).apply(to: Text(verbatim: SettingsWords.syncShort(syncState)))
                        )
                    }
                    ICloudBackupSettingsRow()
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsRowLabel(
                            Text("Appearance"),
                            systemImage: "textformat.size",
                            tint: .blue,
                            value: Text(verbatim: SettingsWords.themeTitle(store.settings.theme))
                        )
                    }
                    NavigationLink {
                        DataSettingsView()
                    } label: {
                        SettingsRowLabel(Text("Import & Export"), systemImage: "externaldrive.fill", tint: .orange)
                    }
                } header: {
                    Text("Vault")
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsRowLabel(
                            Text("About"),
                            systemImage: "info.circle.fill",
                            tint: .gray,
                            value: Text(verbatim: AppVersion.display)
                        )
                    }
                }

                Section {
                    Button("Lock Vault") {
                        store.lock(requestAutomaticUnlock: false)
                    }
                    .disabled(store.isAuthenticated == false || store.isLocked)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .vaultSheetSize(width: 620, height: 620)
        .task { await refreshAutoFillState() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshAutoFillState() }
        }
    }

    private func refreshAutoFillState() async {
        isAutoFillEnabled = await ASCredentialIdentityStore.shared.state().isEnabled
    }
}

/// The account at the top of Settings, as the Apple Account row reads.
private struct AccountSummaryRow: View {
    var email: String
    var host: String
    var needsSignIn: Bool

    var body: some View {
        HStack(spacing: SettingsSpacing.row) {
            AccountAvatar(email: email, baseSide: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: email)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if needsSignIn {
                        StatusTone.attention.apply(to: Text("Sign In Required"))
                    } else {
                        Text(verbatim: host)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, SettingsSpacing.tight)
        .accessibilityElement(children: .combine)
    }
}

/// The iCloud Backup row observes its manager, so its value follows each backup.
private struct ICloudBackupSettingsRow: View {
    @ObservedObject private var backup = ICloudBackupManager.shared

    var body: some View {
        NavigationLink {
            ICloudBackupSettingsView()
        } label: {
            SettingsRowLabel(
                Text("iCloud Backup"),
                systemImage: "icloud.fill",
                tint: .blue,
                value: Text(verbatim: backup.rootRowValue)
            )
        }
    }
}
