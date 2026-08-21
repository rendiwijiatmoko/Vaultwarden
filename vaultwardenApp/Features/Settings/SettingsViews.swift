import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AccountServerSettingsView() } label: {
                        SettingsRow(icon: "person.crop.circle.fill", color: .vaultBlue, title: store.settings.email, subtitle: store.settings.serverURL)
                    }
                }

                Section("Security & Access") {
                    NavigationLink { PendingLoginRequestsView() } label: {
                        SettingsRow(
                            icon: "checkmark.shield.fill",
                            color: .vaultBlue,
                            title: "Approve Login Requests",
                            subtitle: "Review pending device sign-ins"
                        )
                    }
                    NavigationLink { AutoFillSettingsView() } label: {
                        SettingsRow(icon: "rectangle.and.pencil.and.ellipsis", color: .vaultGreen, title: "AutoFill & Passwords", subtitle: "Passwords, passkeys and codes")
                    }
                    NavigationLink { SecuritySettingsView() } label: {
                        SettingsRow(icon: "lock.shield.fill", color: .vaultRed, title: "Security", subtitle: "Biometrics, timeout and clipboard")
                    }
                }

                Section("Vault") {
                    NavigationLink { SyncSettingsView() } label: {
                        SettingsRow(
                            icon: "arrow.triangle.2.circlepath",
                            color: .vaultCyan,
                            title: "Sync",
                            subtitle: store.pendingMutationCount > 0
                                ? L10n.format("%lld encrypted changes queued", store.pendingMutationCount)
                                : store.lastSync.formatted(.relative(presentation: .named))
                        )
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        SettingsRow(icon: "paintpalette.fill", color: .vaultOrange, title: "Appearance", subtitle: store.settings.theme.localizedTitle)
                    }
                    NavigationLink { DataToolsView() } label: {
                        SettingsRow(icon: "externaldrive.fill", color: .vaultYellow, title: "Data & Tools", subtitle: "Import, export and local cache")
                    }
                }

                Section {
                    NavigationLink { AboutView() } label: {
                        SettingsRow(icon: "info.circle.fill", color: .gray, title: "About", subtitle: "Version, privacy and diagnostics")
                    }
                }

                Section {
                    Button(role: .destructive) { store.lock(requestAutomaticUnlock: false) } label: {
                        Label("Lock Vault Now", systemImage: "lock.fill")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title))
                    .foregroundStyle(.primary)
                Text(L10n.string(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AccountServerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var testState: TestState = .idle
    @State private var confirmLogout = false
    @State private var isLoggingOut = false

    private enum TestState {
        case idle
        case testing
        case success(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Email", text: $store.settings.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                LabeledContent("Status", value: store.isAuthenticated ? "Authenticated" : "Signed out")
                LabeledContent("Organizations", value: "\(store.organizations.count)")
            }
            Section("Vaultwarden Server") {
                TextField("https://vault.example.com", text: $store.settings.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    testState = .testing
                    Task {
                        do {
                            let configuration = try await store.testConnection(serverURL: store.settings.serverURL)
                            testState = .success(configuration.version.map { "Server reachable • \($0)" } ?? "Server reachable")
                        } catch {
                            testState = .failed(error.localizedDescription)
                        }
                    }
                } label: {
                    switch testState {
                    case .idle: Label("Test Connection", systemImage: "network")
                    case .testing: HStack { ProgressView(); Text("Testing…") }
                    case let .success(message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Color.vaultGreen)
                    case let .failed(message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section {
                Label("Only HTTPS servers should be accepted in production. Certificate validation must never be disabled.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(role: .destructive) {
                    confirmLogout = true
                } label: {
                    if isLoggingOut {
                        HStack { ProgressView(); Text("Logging Out…") }
                    } else {
                        Text("Log Out")
                    }
                }
                .disabled(!store.isAuthenticated || isLoggingOut)
            }
        }
        .navigationTitle("Account & Server")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Log Out and Delete Local Data?", isPresented: $confirmLogout) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                isLoggingOut = true
                Task {
                    await store.logoutAndDeleteLocalData()
                    isLoggingOut = false
                }
            }
        } message: {
            Text("This removes the local vault, offline changes, cached files, AutoFill data, account details, and local preferences from this device. Data on your Vaultwarden server will not be deleted.")
        }
    }
}

private struct AutoFillSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var statusMessage: String?
    @State private var providerEnabled = false
    @State private var publishedCredentialCount = 0
    @State private var publishedAt: Date?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    VaultIcon(systemName: "rectangle.and.pencil.and.ellipsis", color: .vaultGreen, size: 48)
                    Text("Fill credentials everywhere")
                        .font(.title3.bold())
                    Text("Use passwords and verification codes in Safari and supported apps after enabling the Credential Provider Extension.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Credential Types") {
                LabeledContent("Passwords") { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.vaultGreen) }
                LabeledContent("Verification codes") { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.vaultGreen) }
                LabeledContent("Passkeys") { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.vaultGreen) }
            }

            Section {
                Picker("Default URI match detection", selection: defaultURIMatchDetection) {
                    ForEach(AutoFillURIMatchType.defaultChoices, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
            } header: {
                Text("URI Match Detection")
            } footer: {
                Text("Used when a login URI does not define its own match rule. Per-item URI settings always take priority.")
            }

            Section("Protection") {
                LabeledContent("Unlock before filling", value: "Required")
                Label(
                    "The shared credential vault is encrypted and its key requires biometrics or device authentication.",
                    systemImage: BiometricAuthenticator.systemImage
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider Status") {
                LabeledContent("Enabled in iOS", value: providerEnabled ? "Yes" : "No")
                LabeledContent("Published credentials", value: "\(publishedCredentialCount)")
                if let publishedAt {
                    LabeledContent("Last published", value: publishedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task {
                        await store.sync()
                        await refreshProviderStatus()
                    }
                } label: {
                    if store.isSyncing {
                        HStack { ProgressView(); Text("Publishing…") }
                    } else {
                        Label("Refresh Shared Credentials", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }

            Section {
                Button {
                    ASSettingsHelper.openCredentialProviderAppSettings { error in
                        Task { @MainActor in
                            statusMessage = error == nil ? "Opened Passwords & Codes settings." : error?.localizedDescription
                        }
                    }
                } label: {
                    Label("Open Passwords & Codes Settings", systemImage: "arrow.up.forward.app")
                }

                Button {
                    ASSettingsHelper.openVerificationCodeAppSettings { error in
                        Task { @MainActor in
                            statusMessage = error == nil ? "Opened verification-code app settings." : error?.localizedDescription
                        }
                    }
                } label: {
                    Label("Choose Verification Code App", systemImage: "lock.rotation")
                }
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Label("After enabling Vaultwarden in Passwords & Codes, sync this app once so iOS can refresh domain suggestions.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AutoFill")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshProviderStatus() }
    }

    private func refreshProviderStatus() async {
        let state = await ASCredentialIdentityStore.shared.state()
        providerEnabled = state.isEnabled
        let defaults = UserDefaults(suiteName: AutoFillSharedVault.appGroupIdentifier)
        publishedCredentialCount = defaults?.integer(forKey: AutoFillSharedVault.publishedCountKey) ?? 0
        publishedAt = defaults?.object(forKey: AutoFillSharedVault.publishedAtKey) as? Date
    }

    private var defaultURIMatchDetection: Binding<AutoFillURIMatchType> {
        Binding(
            get: { store.settings.defaultURIMatchDetection ?? .baseDomain },
            set: { store.settings.defaultURIMatchDetection = $0 }
        )
    }
}

private struct SecuritySettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Unlock") {
                Toggle("Unlock with biometrics", isOn: $store.settings.biometricUnlock)
                Toggle("Device passcode fallback", isOn: $store.settings.devicePasscodeFallback)
                Picker("Vault timeout", selection: $store.settings.vaultTimeout) {
                    ForEach(VaultTimeout.allCases) { Text($0.localizedTitle).tag($0) }
                }
            }
            Section("Sensitive Actions") {
                Toggle("Authenticate before reveal or copy", isOn: $store.settings.requireBiometricForSensitiveActions)
                Toggle("Clear clipboard automatically", isOn: $store.settings.clearClipboard)
            }
            Section {
                Button("Deauthorize This Device", role: .destructive) { }
            }
            Section {
                Label(
                    "Biometric unlock will protect a locally wrapped vault key. The master password remains the recovery path.",
                    systemImage: BiometricAuthenticator.systemImage
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SyncSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Last sync", value: store.lastSync.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Server", value: store.settings.serverURL)
                LabeledContent("Queued changes", value: "\(store.pendingMutationCount)")
                if store.lastSyncUsedOfflineCache {
                    Label("Showing encrypted offline cache", systemImage: "externaldrive.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await store.sync() }
                } label: {
                    if store.isSyncing { HStack { ProgressView(); Text("Syncing…") } }
                    else { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                }
                if let error = store.lastSyncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Automatic Sync") {
                Toggle("Automatic sync", isOn: $store.settings.autoSync)
                Toggle("Sync when app opens", isOn: $store.settings.syncOnOpen)
                Toggle("Background refresh", isOn: $store.settings.backgroundRefresh)
            }
            Section {
                Text("Offline changes are stored in a device-only AES-GCM queue, replayed with exponential backoff, and revision-rebased before retry. Background refresh can upload prepared encrypted writes without unlocking the vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $store.settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.localizedTitle).tag($0) }
                }
                Toggle("Show website icons", isOn: $store.settings.showFavicons)
                Toggle("Haptic feedback", isOn: $store.settings.haptics)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DataToolsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var transferMode: VaultTransferMode?
    @State private var pendingImportData: Data?
    @State private var exportedArchive: URL?
    @State private var statusMessage: String?
    @State private var isImportingFile = false
    @State private var confirmClearCache = false

    var body: some View {
        Form {
            Section("Transfer") {
                Button { isImportingFile = true } label: {
                    Label("Import Encrypted Vault", systemImage: "square.and.arrow.down")
                }
                Button { transferMode = .export } label: {
                    Label("Export Encrypted Vault", systemImage: "lock.doc")
                }
                if let exportedArchive {
                    ShareLink(item: exportedArchive) {
                        Label("Save or Share Last Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("Local Data") {
                Button("Clear Encrypted Offline Cache", role: .destructive) { confirmClearCache = true }
            }
            Section {
                Text("Archives use AES-256-GCM with a password-derived key. Organization items and passkeys are excluded; passkeys remain available through server sync. No unencrypted export is provided.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Data & Tools")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingImportData = try Data(contentsOf: url)
                transferMode = .importArchive
            } catch {
                statusMessage = "Could not read the selected archive."
                SecureLog.failure("Archive file read", error: error, logger: SecureLog.crypto)
            }
        }
        .sheet(item: $transferMode) { mode in
            VaultTransferPasswordSheet(mode: mode) { password in
                await performTransfer(mode: mode, password: password)
            }
        }
        .alert("Clear Encrypted Cache?", isPresented: $confirmClearCache) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Cache", role: .destructive) {
                Task {
                    guard await BiometricAuthenticator.authenticate(
                        reason: "Clear the encrypted offline vault cache",
                        allowPasscode: true
                    ) else { return }
                    do { try await store.clearEncryptedLocalCache() }
                    catch { statusMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("This removes the downloaded offline cache. It does not delete server data or queued offline changes.")
        }
    }

    private func performTransfer(mode: VaultTransferMode, password: String) async {
        guard await BiometricAuthenticator.authenticate(
            reason: mode == .export ? "Export your encrypted vault" : "Import credentials into your vault",
            allowPasscode: true
        ) else { return }
        do {
            switch mode {
            case .export:
                exportedArchive = try await store.exportEncryptedVault(password: password)
                statusMessage = "Encrypted archive is ready. Use Save or Share Last Export to store it safely."
            case .importArchive:
                guard let pendingImportData else { throw VaultArchiveError.invalidArchive }
                let summary = try await store.importEncryptedVault(data: pendingImportData, password: password)
                self.pendingImportData = nil
                statusMessage = L10n.format(
                    "Imported %lld items and %lld folders. %lld items failed.",
                    summary.importedItems,
                    summary.importedFolders,
                    summary.failedItems
                )
            }
            transferMode = nil
        } catch {
            statusMessage = error.localizedDescription
            SecureLog.failure("Encrypted archive transfer", error: error, logger: SecureLog.crypto)
        }
    }
}

private enum VaultTransferMode: String, Identifiable {
    case importArchive
    case export

    var id: String { rawValue }
    var title: String { L10n.string(self == .export ? "Export Encrypted Vault" : "Import Encrypted Vault") }
}

private struct VaultTransferPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: VaultTransferMode
    let action: (String) async -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Archive password", text: $password)
                        .textContentType(.newPassword)
                    if mode == .export {
                        SecureField("Confirm archive password", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    Text("Use at least 12 characters. This password cannot be recovered.")
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .export ? "Export" : "Import") {
                        Task {
                            isWorking = true
                            await action(password)
                            isWorking = false
                        }
                    }
                    .disabled(isWorking || password.count < 12 || (mode == .export && password != confirmation))
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.vaultBlue.gradient)
                    Text("Vaultwarden App").font(.title2.bold())
                    Text("Independent iOS client for self-hosted vaults").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section("Version") {
                LabeledContent("Application", value: "\(version) (\(build))")
                LabeledContent("Minimum system", value: "iOS 26.2")
                LabeledContent("Mode", value: "Production")
            }
            Section("Resources") {
                Link("Vaultwarden Project", destination: URL(string: "https://github.com/dani-garcia/vaultwarden")!)
                NavigationLink("Privacy & Security") { PrivacyAndSecurityView() }
                NavigationLink("Open Source Licenses") { LicensesView() }
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
            Section {
                Text("This project is not affiliated with Bitwarden, Inc. Product naming and licensing must be reviewed before distribution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyAndSecurityView: View {
    var body: some View {
        List {
            Section("Data Handling") {
                Text("Vault data is sent only to the Vaultwarden server configured by the user. The app has no analytics, advertising SDK, or tracking domains.")
                Text("Offline vault data, mutation queues, and the AutoFill index are encrypted on device. Keys are stored in iOS Keychain and are not included in exports.")
            }
            Section("Exports") {
                Text("Encrypted archives require device authentication and a separate archive password. Organization items and passkeys are excluded from archives.")
            }
            Section("Independent Client") {
                Text("This app is not affiliated with Bitwarden, Inc. or the Vaultwarden project.")
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicensesView: View {
    var body: some View {
        List {
            Section("Bitwarden SDK for Swift") {
                LabeledContent("Revision", value: "3dbc27249f48")
                Link("Upstream Source", destination: URL(string: "https://github.com/bitwarden/sdk-swift")!)
                Text("Release gate: the pinned sdk-swift snapshot does not include a LICENSE file. Confirm the binary FFI and generated bindings' distribution terms with Bitwarden, then include the complete license text and corresponding-source obligations before App Store submission.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Section("Vaultwarden") {
                Text("The Vaultwarden server is not bundled or redistributed by this app. The app communicates with a server chosen by the user.")
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Session", value: store.isAuthenticated ? "Present" : "Not present")
                LabeledContent("Vault", value: store.isLocked ? "Locked" : "Unlocked")
                LabeledContent("Queued changes", value: "\(store.pendingMutationCount)")
                LabeledContent("Offline cache", value: store.lastSyncUsedOfflineCache ? "In use" : "Not in use")
            }
            Section {
                Text("Diagnostics intentionally omit server URLs, email addresses, item names, usernames, tokens, keys, and raw errors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
