#if os(macOS)
import SwiftUI

/// The SSH Agent pane: whether it runs, how a shell reaches it, and which keys it offers.
struct SSHAgentSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var agent: MacSSHAgent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var availableKeys: [VaultItem] {
        store.items.filter { store.canUseSSHKey($0) && (try? SSHAgentSigner.publicBlob($0.username)) != nil }
    }

    private var isEnabled: Bool { store.settings.sshAgentEnabled == true }

    private var allowedKeyIDs: Set<UUID> { Set(store.settings.sshAgentAllowedKeyIDs ?? []) }

    private var enabledKeyCount: Int {
        availableKeys.filter { allowedKeyIDs.contains($0.id) }.count
    }

    private var heroLine: Text {
        let line = SettingsWords.sshHeadline(
            isEnabled: isEnabled,
            isRunning: agent.isRunning,
            startupFailed: agent.startupFailed,
            enabledKeys: enabledKeyCount
        )
        return SettingsWords.sshTone(isEnabled: isEnabled, isRunning: agent.isRunning, startupFailed: agent.startupFailed)
            .apply(to: Text(verbatim: line))
    }

    var body: some View {
        Form {
            SettingsHero(
                Text("SSH Agent"),
                subtitle: heroLine,
                systemImage: "terminal.fill",
                tint: .gray
            ) {
                Toggle("SSH Agent", isOn: enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(store.isAuthenticated == false)
            }

            if isEnabled && agent.startupFailed {
                Section {
                    SettingsDetailRow(
                        title: Text("Couldn’t Start"),
                        detail: Text("Another copy of Vaultwarden may be running, or this build can’t reach its App Group container.")
                    ) {
                        Button("Try Again") { agent.retry() }
                    }
                }
            }

            if isEnabled {
                Section {
                    if agent.socketPath != nil {
                        HStack(alignment: .top, spacing: SettingsSpacing.row) {
                            Text(verbatim: agent.shellConfiguration)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AnimatedCopyButton(
                                value: agent.shellConfiguration,
                                title: "Copy",
                                accessibilityName: "SSH agent configuration"
                            )
                        }
                        .padding(SettingsSpacing.row)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    } else {
                        StatusTone.attention.apply(to: Text("The SSH socket isn’t available in this build. Run a signed build with App Group access."))
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    if agent.socketPath != nil {
                        Text("Add this line to ~/.zshrc, then open a new Terminal window. Check it with ssh-add -L. Vaultwarden needs to keep running.")
                    }
                }

                Section {
                    if store.isLocked || store.isAuthenticated == false {
                        Text("Unlock your vault to choose keys.")
                            .foregroundStyle(.secondary)
                    } else if availableKeys.isEmpty {
                        Text("Add an Ed25519 or RSA SSH key to your vault to use it here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableKeys) { item in
                            SSHKeyRow(
                                item: item,
                                isAllowed: allowed(item),
                                isAlwaysAllowed: agent.isAlwaysApproved(item),
                                onAskAgain: { agent.revokeAlwaysApproval(for: item.id) }
                            )
                        }
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Keys are offered only after you turn them on. Always Allow lets any app on this Mac use that key while your vault is unlocked; Ask Every Time takes it back.")
                }
            }
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: isEnabled)
        .settingsPane()
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { store.settings.sshAgentEnabled == true },
            set: { store.settings.sshAgentEnabled = $0 }
        )
    }

    /// Turning a key off also forgets its Always Allow, so turning it back on asks again.
    private func allowed(_ item: VaultItem) -> Binding<Bool> {
        Binding(
            get: { (store.settings.sshAgentAllowedKeyIDs ?? []).contains(item.id) },
            set: { isAllowed in
                var ids = Set(store.settings.sshAgentAllowedKeyIDs ?? [])
                if isAllowed { ids.insert(item.id) } else { ids.remove(item.id) }
                var settings = store.settings
                settings.sshAgentAllowedKeyIDs = Array(ids)
                if isAllowed == false {
                    settings.sshAgentApprovals?.removeAll { $0.keyID == item.id }
                }
                store.settings = settings
            }
        )
    }
}

/// One key: its name and fingerprint, its switch, and whether it still asks.
private struct SSHKeyRow: View {
    let item: VaultItem
    @Binding var isAllowed: Bool
    let isAlwaysAllowed: Bool
    let onAskAgain: () -> Void

    private var fingerprint: String {
        guard let blob = try? SSHAgentSigner.publicBlob(item.username) else { return "" }
        return SSHAgentSigner.fingerprint(blob)
    }

    var body: some View {
        SettingsDetailRow(
            title: Text(verbatim: item.name),
            detail: Text(verbatim: fingerprint).monospaced(),
            systemImage: "key.horizontal.fill",
            tint: .gray
        ) {
            HStack(spacing: SettingsSpacing.standard) {
                if isAllowed && isAlwaysAllowed {
                    Button("Ask Every Time", action: onAskAgain)
                        .help("Ask before any app uses this key again")
                }
                Toggle(item.name, isOn: $isAllowed)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

struct SSHAgentPresentation: ViewModifier {
    @EnvironmentObject private var agent: MacSSHAgent
    @EnvironmentObject private var menuBar: MacMenuBarController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onAppear {
                menuBar.openVaultWindow = { openWindow(id: "vault") }
                menuBar.openSettingsWindow = { openSettings() }
                agent.presentRequest = { [weak menuBar = menuBar] in menuBar?.presentSSHRequest() }
            }
            .sheet(item: Binding(
                get: { menuBar.isEnabled ? nil : agent.prompt },
                set: { if $0 == nil && !menuBar.isEnabled { agent.resolvePrompt(approved: false) } }
            )) { prompt in
                SSHAgentAuthorizationView(prompt: prompt)
            }
    }
}

/// Asks whether a local SSH client may use a key, or unlock to list keys.
struct SSHAgentAuthorizationView: View {
    let prompt: SSHAgentPrompt
    var compact = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var agent: MacSSHAgent
    @State private var masterPassword = ""
    @State private var unlocking = false
    @State private var unlockFailed = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: SettingsSpacing.row) {
                SettingsIconTile(systemImage: "terminal.fill", color: .gray, baseSide: 40)
                Group {
                    if prompt.keyName == nil {
                        Text("SSH Keys Requested")
                    } else {
                        Text("Allow SSH Access?")
                    }
                }
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            }
            if let name = prompt.keyName, let fingerprint = prompt.fingerprint {
                VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                    Text(verbatim: name).font(.headline).textSelection(.enabled)
                    Text(verbatim: fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Text("Allow only if you just ran ssh or Git. Vaultwarden can’t see which server the request is for. Always Allow lets apps on this Mac use this key without asking while your vault is unlocked; change it in Settings ▸ SSH Agent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("An SSH client wants to see which keys are available. Unlock your vault to continue.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isLocked {
                VStack(alignment: .leading, spacing: SettingsSpacing.standard) {
                    if store.settings.biometricUnlock {
                        Button {
                            Task { await unlockWithBiometrics() }
                        } label: {
                            Label(
                                L10n.format("Unlock with %@", BiometricAuthenticator.displayName),
                                systemImage: BiometricAuthenticator.systemImage
                            )
                        }
                    }
                    HStack(spacing: SettingsSpacing.standard) {
                        SecureField("Master Password", text: $masterPassword)
                            .textFieldStyle(.roundedBorder)
                            .focused($isPasswordFocused)
                            .onSubmit { unlockWithPassword() }
                        Button("Unlock") { unlockWithPassword() }
                            .disabled(masterPassword.isEmpty)
                    }
                    if unlockFailed {
                        StatusTone.failure.apply(to: Text("That didn’t unlock the vault. Try again."))
                            .font(.callout)
                    }
                }
            }
            HStack {
                Button("Deny", role: .cancel) { agent.resolvePrompt(id: prompt.id, approved: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if prompt.keyName != nil {
                    Button("Always Allow") { agent.resolvePrompt(id: prompt.id, approved: true, alwaysApprove: true) }
                        .disabled(store.isLocked || unlocking)
                    Button("Allow Once") { agent.resolvePrompt(id: prompt.id, approved: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLocked || unlocking)
                } else if store.isLocked == false {
                    Button("Continue") { agent.resolvePrompt(id: prompt.id, approved: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(unlocking)
                }
            }
        }
        .padding(compact ? 0 : 24)
        .frame(width: compact ? nil : 500)
        .disabled(unlocking)
        .onChange(of: store.isLocked) { _, _ in
            masterPassword = ""
        }
        .onDisappear {
            masterPassword = ""
            agent.cancelPrompt(id: prompt.id)
        }
    }

    private func unlockWithBiometrics() async {
        unlocking = true
        let success = await store.unlockWithBiometrics()
        unlockFailed = !success
        unlocking = false
        if success && prompt.keyName == nil { agent.resolvePrompt(id: prompt.id, approved: true) }
    }

    private func unlockWithPassword() {
        guard !masterPassword.isEmpty, !unlocking else { return }
        let password = masterPassword
        masterPassword = ""
        Task {
            unlocking = true
            let success = await store.unlock(masterPassword: password)
            unlockFailed = !success
            unlocking = false
            if success && prompt.keyName == nil { agent.resolvePrompt(id: prompt.id, approved: true) }
            if !success { isPasswordFocused = true }
        }
    }
}
#endif
