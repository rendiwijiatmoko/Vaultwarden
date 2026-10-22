#if os(macOS)
import AppKit
import SwiftUI

/// A compact vault surface. It shares the app's store and never caches vault items.
struct MacMenuBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var agent: MacSSHAgent
    let controller: MacMenuBarController
    @State private var tab = Tab.vault
    @State private var query = ""
    @State private var copyNotice: String?
    @State private var copying = false

    private enum Tab: String, CaseIterable {
        case vault = "Vault", generator = "Generator", ssh = "SSH Agent"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt = agent.prompt {
                        SSHAgentAuthorizationView(prompt: prompt, compact: true)
                            .id(prompt.id)
                    } else {
                        Picker("Quick access", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if tab == .generator {
                            MacQuickGeneratorView()
                        } else if !store.isAuthenticated {
                            Text("Sign in to access your vault.").foregroundStyle(.secondary)
                            Button("Sign In") { controller.openVault() }
                                .buttonStyle(.borderedProminent)
                        } else if store.isLocked {
                            MacQuickUnlockView(store: store)
                        } else if tab == .vault {
                            vault
                        } else {
                            ssh
                        }
                    }
                }
                .padding(16)
            }
            if let copyNotice {
                Text(copyNotice).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(width: 390, height: 550)
        .preferredColorScheme(store.settings.theme == .system ? nil : (store.settings.theme == .dark ? .dark : .light))
        .onChange(of: store.isLocked) { _, _ in query = ""; copyNotice = nil }
        .onChange(of: store.authenticatedSession?.tokenReference) { _, _ in query = ""; copyNotice = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vaultwarden").font(.headline)
                Text(L10n.string(!store.isAuthenticated ? "Signed out" : (store.isLocked ? "Vault Locked" : "Vault Unlocked")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isAuthenticated && !store.isLocked {
                Button { store.lock(requestAutomaticUnlock: false) } label: {
                    Image(systemName: "lock.fill")
                }
                .help("Lock Vault")
                .accessibilityLabel("Lock Vault")
            }
        }
        .padding(16)
    }

    private var vault: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search vault", text: $query)
                .textFieldStyle(.roundedBorder)
            let results = store.search(query)
            if results.isEmpty {
                Text("No matching items").foregroundStyle(.secondary).padding(.vertical)
            }
            ForEach(Array(results.prefix(30))) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.type == .sshKey ? "terminal" : "key.fill")
                        .foregroundStyle(.secondary).frame(width: 22)
                    Button {
                        store.selectedItemID = item.id
                        controller.openVault()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).fontWeight(.medium).lineLimit(1)
                            Text(item.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item.type == .login {
                        if !item.username.isEmpty {
                            Button { copy(itemID: item.id, password: false) } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .help("Copy Username").accessibilityLabel("Copy Username")
                        }
                        if !item.password.isEmpty && store.canCopyLoginPassword(item) {
                            Button { copy(itemID: item.id, password: true) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("Copy Password").accessibilityLabel("Copy Password")
                        }
                    }
                }
                .disabled(copying)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            if results.count > 30 {
                Text("Refine your search to see more items.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable SSH Agent", isOn: Binding(
                get: { store.settings.sshAgentEnabled == true },
                set: { store.settings.sshAgentEnabled = $0 }
            ))
            Label(L10n.string(agent.isRunning ? "Running" : "Stopped"), systemImage: agent.isRunning ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(agent.isRunning ? .green : .secondary)
            if agent.startupFailed {
                Text("Could not start SSH agent. Check App Group access, socket path length, and whether another app instance is running.")
                    .font(.caption).foregroundStyle(.red)
                Button("Retry") { agent.retry() }
            }
            if agent.socketPath != nil {
                AnimatedCopyButton(value: agent.shellConfiguration, title: "Copy Configuration", accessibilityName: "SSH agent configuration")
            }
            Text("Available SSH Keys").font(.headline)
            ForEach(store.items.filter { store.canUseSSHKey($0) }) { item in
                Toggle(item.name, isOn: Binding(
                    get: { (store.settings.sshAgentAllowedKeyIDs ?? []).contains(item.id) },
                    set: { enabled in
                        var settings = store.settings
                        var ids = Set(settings.sshAgentAllowedKeyIDs ?? [])
                        if enabled { ids.insert(item.id) } else { ids.remove(item.id) }
                        settings.sshAgentAllowedKeyIDs = Array(ids)
                        if !enabled { settings.sshAgentApprovals?.removeAll { $0.keyID == item.id } }
                        store.settings = settings
                    }
                ))
                if agent.isAlwaysApproved(item) {
                    Button("Require Approval Again") { agent.revokeAlwaysApproval(for: item.id) }
                        .font(.caption)
                }
            }
            Text("SSH requests appear here. Unlock and approve without opening the main window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Vaultwarden") { controller.openVault() }
            Spacer()
            Button { Task { await store.sync() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .disabled(!store.isAuthenticated || store.isLocked || store.isSyncing)
                .help("Sync Now").accessibilityLabel("Sync Now")
            Button { controller.openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings…").accessibilityLabel("Settings…")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Vaultwarden").accessibilityLabel("Quit Vaultwarden")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private func copy(itemID: UUID, password: Bool) {
        guard !copying, !store.isLocked else { return }
        let session = store.authenticatedSession?.tokenReference
        let generation = store.vaultGeneration
        copying = true
        Task { @MainActor in
            defer { copying = false }
            if store.settings.requireBiometricForSensitiveActions {
                guard await BiometricAuthenticator.authenticate(
                    reason: "Copy vault credential", allowPasscode: store.settings.devicePasscodeFallback
                ) else { return }
            }
            // Re-resolve after authentication: locking, account or permissions may have changed.
            guard !store.isLocked, store.isAuthenticated,
                  generation == store.vaultGeneration,
                  session == store.authenticatedSession?.tokenReference,
                  let item = store.activeItems.first(where: { $0.id == itemID }),
                  item.type == .login, !password || store.canCopyLoginPassword(item) else { return }
            Clipboard.copy(password ? item.password : item.username)
            copyNotice = L10n.string("Copied")
        }
    }
}

private struct MacQuickUnlockView: View {
    @ObservedObject var store: AppStore
    @State private var password = ""
    @State private var unlocking = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vault Locked", systemImage: "lock.fill").font(.title3.bold())
            Button("Unlock Vault") { unlock(biometrics: true) }
                .buttonStyle(.borderedProminent)
            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder).onSubmit { unlock(biometrics: false) }
            Button("Unlock with Master Password") { unlock(biometrics: false) }
                .disabled(password.isEmpty)
            if failed { Text("Could not unlock vault. Please try again.").font(.caption).foregroundStyle(.red) }
        }
        .disabled(unlocking)
        .onDisappear { password = "" }
    }

    private func unlock(biometrics: Bool) {
        guard !unlocking, biometrics || !password.isEmpty else { return }
        let supplied = password
        password = ""
        unlocking = true
        Task { @MainActor in
            let success = biometrics ? await store.unlockWithBiometrics() : await store.unlock(masterPassword: supplied)
            failed = !success
            unlocking = false
        }
    }
}

private struct MacQuickGeneratorView: View {
    @State private var generated = PasswordGenerator.password(length: 20, uppercase: true, numbers: true, symbols: true)
    @State private var length = 20.0
    @State private var uppercase = true
    @State private var numbers = true
    @State private var symbols = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Password").font(.headline)
            Text(generated).font(.title3.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Length")
                Slider(value: $length, in: 8...64, step: 1)
                Text(Int(length), format: .number).monospacedDigit()
            }
            Toggle("Uppercase", isOn: $uppercase)
            Toggle("Numbers", isOn: $numbers)
            Toggle("Symbols", isOn: $symbols)
            HStack {
                Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
                Spacer()
                AnimatedCopyButton(value: generated, title: "Copy", accessibilityName: "generated value")
                    .buttonStyle(.borderedProminent)
            }
        }
        .onChange(of: length) { _, _ in regenerate() }
        .onChange(of: uppercase) { _, _ in regenerate() }
        .onChange(of: numbers) { _, _ in regenerate() }
        .onChange(of: symbols) { _, _ in regenerate() }
    }

    private func regenerate() {
        generated = PasswordGenerator.password(length: Int(length), uppercase: uppercase, numbers: numbers, symbols: symbols)
    }
}
#endif
