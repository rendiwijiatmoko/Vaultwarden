#if os(macOS)
import SwiftUI

struct SSHAgentSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var agent: MacSSHAgent

    private var availableKeys: [VaultItem] {
        store.items.filter { store.canUseSSHKey($0) && (try? SSHAgentSigner.publicBlob($0.username)) != nil }
    }

    var body: some View {
        Form {
            Section("SSH Agent") {
                Toggle("Enable SSH Agent", isOn: Binding(
                    get: { store.settings.sshAgentEnabled == true },
                    set: { store.settings.sshAgentEnabled = $0 }
                ))
                .disabled(!store.isAuthenticated)
                LabeledContent("Status") {
                    Text(L10n.string(agent.isRunning ? "Running" : "Stopped"))
                }
                Text("Use vault SSH keys with SSH and Git. Approve each request or remember approval for a selected key.")
                    .foregroundStyle(.secondary)
                if agent.startupFailed {
                    Text("Could not start SSH agent. Check App Group access, socket path length, and whether another app instance is running.")
                        .foregroundStyle(.red)
                    Button("Retry") { agent.retry() }
                }
            }
            Section("Terminal Setup") {
                if let path = agent.socketPath {
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(agent.shellConfiguration).font(.caption.monospaced()).textSelection(.enabled)
                    AnimatedCopyButton(value: agent.shellConfiguration, title: "Copy Configuration",
                                       accessibilityName: "SSH agent configuration")
                    Text("Add this command to ~/.zshrc and open a new terminal. Keep Vaultwarden running. Test with ssh-add -L, then ssh -T git@github.com after registering your public key.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("SSH socket is unavailable. Run a signed build with the configured App Group entitlement.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Available SSH Keys") {
                if store.isLocked || !store.isAuthenticated {
                    Text("Unlock your vault to select SSH keys.").foregroundStyle(.secondary)
                } else if availableKeys.isEmpty {
                    Text("Create or import an Ed25519 or RSA SSH key first.").foregroundStyle(.secondary)
                } else {
                    ForEach(availableKeys) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(
                                get: { (store.settings.sshAgentAllowedKeyIDs ?? []).contains(item.id) },
                                set: { enabled in
                                    var ids = Set(store.settings.sshAgentAllowedKeyIDs ?? [])
                                    if enabled { ids.insert(item.id) } else { ids.remove(item.id) }
                                    var settings = store.settings
                                    settings.sshAgentAllowedKeyIDs = Array(ids)
                                    if !enabled {
                                        settings.sshAgentApprovals?.removeAll { $0.keyID == item.id }
                                    }
                                    store.settings = settings
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    if let blob = try? SSHAgentSigner.publicBlob(item.username) {
                                        Text(SSHAgentSigner.fingerprint(blob)).font(.caption.monospaced())
                                            .foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                            if agent.isAlwaysApproved(item) {
                                HStack {
                                    Text("Always Approve is enabled.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Require Approval Again") { agent.revokeAlwaysApproval(for: item.id) }
                                }
                            }
                        }
                    }
                }
                Text("No keys are enabled by default. Deleted, archived, and restricted keys are unavailable. RSA requires SHA-256 or SHA-512 signatures.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Always Approve applies to all local SSH clients using that key while the vault is unlocked. It is saved on this Mac and can be revoked here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SSH Agent")
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
                agent.presentRequest = { [weak menuBar] in menuBar?.presentSSHRequest() }
            }
            .sheet(item: Binding(
                get: { menuBar.isEnabled ? nil : agent.prompt },
                set: { if $0 == nil && !menuBar.isEnabled { agent.resolvePrompt(approved: false) } }
            )) { prompt in
                SSHAgentAuthorizationView(prompt: prompt)
            }
    }
}

struct SSHAgentAuthorizationView: View {
    let prompt: SSHAgentPrompt
    var compact = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var agent: MacSSHAgent
    @State private var masterPassword = ""
    @State private var unlocking = false
    @State private var unlockFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("SSH Agent Request", systemImage: "terminal.fill").font(.title2.bold())
            if let name = prompt.keyName, let fingerprint = prompt.fingerprint {
                Text("Allow this SSH client to use the following key?")
                Text(name).font(.headline).textSelection(.enabled)
                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("Approve only requests you initiated. The agent cannot verify the destination host from this request.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Always Approve lets local SSH clients use this key without asking again while the vault is unlocked. Change this in Settings → SSH Agent.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("An SSH client needs access to your available public keys. Unlock your vault to continue.")
            }
            if store.isLocked {
                Button("Unlock Vault") {
                    Task {
                        unlocking = true
                        let success = await store.unlockWithBiometrics()
                        unlockFailed = !success
                        unlocking = false
                        if success && prompt.keyName == nil { agent.resolvePrompt(id: prompt.id, approved: true) }
                    }
                }
                SecureField("Master password", text: $masterPassword)
                    .onSubmit { unlockWithPassword() }
                Button("Unlock with Master Password") { unlockWithPassword() }
                    .disabled(masterPassword.isEmpty)
                if unlockFailed { Text("Could not unlock vault. Please try again.").foregroundStyle(.red) }
            }
            HStack {
                Button("Deny", role: .cancel) { agent.resolvePrompt(id: prompt.id, approved: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if prompt.keyName != nil {
                    Button("Always Approve") { agent.resolvePrompt(id: prompt.id, approved: true, alwaysApprove: true) }
                        .disabled(store.isLocked || unlocking)
                    Button("Approve Once") { agent.resolvePrompt(id: prompt.id, approved: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLocked || unlocking)
                } else if !store.isLocked {
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
        }
    }
}
#endif
