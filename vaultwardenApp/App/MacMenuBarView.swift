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
    @State private var selectedItemID: UUID?
    @State private var copiedFieldID: String?

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
        .onChange(of: tab) { _, _ in selectedItemID = nil; copyNotice = nil; copiedFieldID = nil }
        .onChange(of: store.isLocked) { _, _ in query = ""; copyNotice = nil; selectedItemID = nil; copiedFieldID = nil }
        .onChange(of: store.authenticatedSession?.tokenReference) { _, _ in query = ""; copyNotice = nil; selectedItemID = nil; copiedFieldID = nil }
        .onDisappear { selectedItemID = nil; copiedFieldID = nil; copyNotice = nil }
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

    @ViewBuilder private var vault: some View {
        if let id = selectedItemID, let item = store.activeItems.first(where: { $0.id == id }) {
            itemDetail(item)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Search vault", text: $query)
                    .textFieldStyle(.roundedBorder)
                let sections = VaultQuickAccessSections(items: store.search(query), sortOrder: store.settings.vaultSortOrder)
                if sections.favorites.isEmpty && sections.otherItems.isEmpty {
                    Text("No matching items").foregroundStyle(.secondary).padding(.vertical)
                }
                if !sections.favorites.isEmpty {
                    itemSection("Favorites", symbol: "star.fill", items: sections.favorites)
                }
                if !sections.otherItems.isEmpty {
                    itemSection("Other Items", symbol: "square.stack", items: sections.otherItems)
                }
            }
        }
    }

    private func itemSection(_ title: String, symbol: String, items: [VaultItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string(title), systemImage: symbol)
                Spacer()
                Text(items.count, format: .number).monospacedDigit()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                Button {
                    selectedItemID = item.id
                    copyNotice = nil
                    copiedFieldID = nil
                } label: {
                    HStack(spacing: 10) {
                        thumbnail(item, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(item.name).fontWeight(.medium).lineLimit(1)
                                if item.isFavorite {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                }
                            }
                            Text(item.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.totpSecret?.isEmpty == false {
                            Image(systemName: "lock.rotation").foregroundStyle(.secondary)
                                .accessibilityLabel("Verification code")
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func thumbnail(_ item: VaultItem, size: CGFloat) -> some View {
        VaultItemThumbnail(item: item, showsWebsiteIcon: store.settings.showFavicons,
                           serverURL: store.authenticatedSession?.serverURL, size: size)
    }

    private func itemDetail(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    selectedItemID = nil
                    copyNotice = nil
                    copiedFieldID = nil
                } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Button {
                    store.selectedItemID = item.id
                    controller.openVault()
                } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open Vaultwarden").accessibilityLabel("Open Vaultwarden")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 12) {
                thumbnail(item, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name).font(.headline)
                        if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                    Text(item.type.localizedTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Choose a field to copy").font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fields = store.quickCopyFields(for: item, date: context.date)
                VStack(spacing: 8) {
                    if fields.isEmpty {
                        Text("No copyable fields").foregroundStyle(.secondary)
                    }
                    ForEach(fields) { field in
                        Button { copy(itemID: item.id, fieldID: field.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: field.symbol).foregroundStyle(.tint).frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(field.isCustom ? field.title : L10n.string(field.title))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: field.isSensitive ? "••••••••" : field.value)
                                        .font(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if field.id == "totp", let secret = item.totpSecret {
                                    let period = TOTPGenerator.period(secret: secret)
                                    Text("\(period - Int(context.date.timeIntervalSince1970) % period)s")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Image(systemName: copiedFieldID == field.id ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedFieldID == field.id ? Color.green : Color.secondary)
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(copying)
                        .accessibilityLabel(L10n.format("Copy %@", field.isCustom ? field.title : L10n.string(field.title)))
                    }
                }
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

    private func copy(itemID: UUID, fieldID: String) {
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
                  selectedItemID == itemID, tab == .vault,
                  generation == store.vaultGeneration,
                  session == store.authenticatedSession?.tokenReference,
                  let item = store.activeItems.first(where: { $0.id == itemID }),
                  let field = store.quickCopyFields(for: item).first(where: { $0.id == fieldID }) else { return }
            Clipboard.copy(field.value)
            copiedFieldID = field.id
            copyNotice = L10n.format("%@ copied", field.isCustom ? field.title : L10n.string(field.title))
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
