#if os(macOS)
import AppKit
import SwiftUI

/// A compact vault surface. It shares the app's store and never caches vault items.
///
/// Keyboard path: the search field is focused on open, Up and Down move the
/// highlight, Return opens an item, Escape clears the search, then closes.
/// In an item, Up and Down move between fields, Return copies, Escape goes back.
struct MacMenuBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var agent: MacSSHAgent
    let controller: MacMenuBarController
    @State private var tab = Tab.vault

    private enum Tab: String, CaseIterable {
        case vault = "Vault", generator = "Generator", ssh = "SSH Agent"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if agent.prompt == nil {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 390, height: 550)
        .preferredColorScheme(store.settings.theme == .system ? nil : (store.settings.theme == .dark ? .dark : .light))
    }

    @ViewBuilder private var content: some View {
        if let prompt = agent.prompt {
            ScrollView {
                SSHAgentAuthorizationView(prompt: prompt, compact: true)
                    .id(prompt.id)
                    .padding(14)
            }
        } else if tab == .generator {
            ScrollView {
                MacQuickGeneratorView()
                    .padding(14)
            }
        } else if !store.isAuthenticated {
            ContentUnavailableView {
                Label("Not Signed In", systemImage: "person.crop.circle")
            } actions: {
                Button("Sign In…") { controller.openVault() }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.isLocked {
            MacQuickUnlockView(store: store)
                .padding(14)
        } else if tab == .vault {
            // A new identity per account and unlock drops search, highlight
            // and copy state instead of carrying it across.
            MenuBarVaultPanel(store: store, controller: controller)
                .id(store.authenticatedSession?.tokenReference)
        } else {
            ScrollView {
                ssh.padding(14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vaultwarden").font(.headline)
                Text(L10n.string(!store.isAuthenticated ? "Signed out" : (store.isLocked ? "Vault Locked" : "Vault Unlocked")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isAuthenticated && !store.isLocked {
                Button("Lock Vault", systemImage: "lock.fill") { store.lock(requestAutomaticUnlock: false) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 28, minHeight: 28)
                    .help("Lock Vault")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("SSH Agent", isOn: Binding(
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
            let keys = store.items.filter { store.canUseSSHKey($0) }
            if !keys.isEmpty {
                Text("Available SSH Keys")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            ForEach(keys) { item in
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Open Vaultwarden") { controller.openVault() }
            Spacer()
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await store.sync() } }
                .disabled(!store.isAuthenticated || store.isLocked || store.isSyncing)
                .help("Sync Now")
            Button("Settings…", systemImage: "gearshape") { controller.openSettings() }
                .help("Settings…")
            Button("Quit Vaultwarden", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .help("Quit Vaultwarden")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Vault list

private struct MenuBarVaultPanel: View {
    @ObservedObject var store: AppStore
    let controller: MacMenuBarController
    @State private var query = ""
    @State private var highlightedID: UUID?
    @State private var scrollTarget: UUID?
    @State private var selectedItemID: UUID?
    @FocusState private var searchFocused: Bool

    private var sections: VaultQuickAccessSections {
        VaultQuickAccessSections(items: store.search(query), sortOrder: store.settings.vaultSortOrder)
    }

    var body: some View {
        if let id = selectedItemID, let item = store.activeItems.first(where: { $0.id == id }) {
            MenuBarItemDetail(store: store, controller: controller, item: item) {
                selectedItemID = nil
                searchFocused = true
            }
        } else {
            list
        }
    }

    private var list: some View {
        let sections = sections
        return VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Search Vault"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
                .onExitCommand {
                    if query.isEmpty { controller.closePopover() } else { query = "" }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if sections.favorites.isEmpty && sections.otherItems.isEmpty {
                            Text(query.isEmpty ? "No Items" : "No Results")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                        if !sections.favorites.isEmpty {
                            section("Favorites", items: sections.favorites)
                        }
                        if !sections.otherItems.isEmpty {
                            section(sections.favorites.isEmpty ? "All Items" : "Other Items", items: sections.otherItems)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target)
                }
            }
        }
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in
            highlightedID = orderedIDs.first
        }
    }

    private func section(_ title: String, items: [VaultItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string(title))
                Spacer()
                Text(items.count, format: .number).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(items) { item in
                Button { open(item.id) } label: {
                    MenuBarItemRow(
                        item: item,
                        isHighlighted: highlightedID == item.id,
                        showsWebsiteIcon: store.settings.showFavicons,
                        serverURL: store.authenticatedSession?.serverURL
                    )
                }
                .buttonStyle(.plain)
                .id(item.id)
                .onHover { hovering in
                    if hovering { highlightedID = item.id }
                }
            }
        }
    }

    private var orderedIDs: [UUID] {
        let sections = sections
        return (sections.favorites + sections.otherItems).map(\.id)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let ids = orderedIDs
        guard !ids.isEmpty else { return .ignored }
        let next: Int
        if let highlightedID, let index = ids.firstIndex(of: highlightedID) {
            next = min(max(index + offset, 0), ids.count - 1)
        } else {
            next = offset > 0 ? 0 : ids.count - 1
        }
        highlightedID = ids[next]
        scrollTarget = ids[next]
        return .handled
    }

    private func openHighlighted() {
        guard let id = highlightedID ?? orderedIDs.first else { return }
        open(id)
    }

    private func open(_ id: UUID) {
        highlightedID = id
        selectedItemID = id
    }
}

private struct MenuBarItemRow: View {
    let item: VaultItem
    let isHighlighted: Bool
    let showsWebsiteIcon: Bool
    let serverURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            VaultItemThumbnail(item: item, showsWebsiteIcon: showsWebsiteIcon, serverURL: serverURL, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name).lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                if !item.displaySubtitle.isEmpty {
                    Text(item.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.totpSecret?.isEmpty == false {
                Image(systemName: "lock.rotation")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Verification code")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .contentShape(.rect)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
            }
        }
    }
}

// MARK: - Item detail

private struct MenuBarItemDetail: View {
    @ObservedObject var store: AppStore
    let controller: MacMenuBarController
    let item: VaultItem
    let onBack: () -> Void
    @State private var highlightedFieldID: String?
    @State private var copiedFieldID: String?
    @State private var copyNotice: String?
    @State private var copying = false
    @FocusState private var focused: Bool

    private var hasCode: Bool { item.totpSecret?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: onBack)
                Spacer()
                Button("Open in Vaultwarden", systemImage: "arrow.up.forward.app") {
                    store.selectedItemID = item.id
                    controller.openVault()
                }
                .labelStyle(.iconOnly)
                .help("Open in Vaultwarden")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HStack(spacing: 12) {
                VaultItemThumbnail(
                    item: item,
                    showsWebsiteIcon: store.settings.showFavicons,
                    serverURL: store.authenticatedSession?.serverURL,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Text(item.type.localizedTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // Ticks only for items with a code; nothing else here changes.
            TimelineView(.periodic(from: .now, by: hasCode ? 1 : 3_600)) { context in
                let fields = store.quickCopyFields(for: item, date: context.date)
                ScrollView {
                    VStack(spacing: 0) {
                        if fields.isEmpty {
                            Text("Nothing to Copy")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        }
                        ForEach(fields) { field in
                            fieldRow(field, date: context.date)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onKeyPress(.downArrow) { move(by: 1, in: fields) }
                .onKeyPress(.upArrow) { move(by: -1, in: fields) }
                .onKeyPress(.return) {
                    guard let id = highlightedFieldID ?? fields.first?.id else { return .ignored }
                    copy(fieldID: id)
                    return .handled
                }
            }

            if let copyNotice {
                Text(copyNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand(perform: onBack)
    }

    private func fieldRow(_ field: VaultQuickCopyField, date: Date) -> some View {
        let title = field.isCustom ? field.title : L10n.string(field.title)
        let isCopied = copiedFieldID == field.id
        return Button { copy(fieldID: field.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: field.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: field.isSensitive ? "••••••••" : field.value)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if field.id == "totp", let secret = item.totpSecret {
                    let period = TOTPGenerator.period(secret: secret)
                    Text("\(period - Int(date.timeIntervalSince1970) % period)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background {
                if highlightedFieldID == field.id {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(copying)
        .onHover { hovering in
            if hovering { highlightedFieldID = field.id }
        }
        .accessibilityLabel(L10n.format("Copy %@", title))
    }

    private func move(by offset: Int, in fields: [VaultQuickCopyField]) -> KeyPress.Result {
        guard !fields.isEmpty else { return .ignored }
        let next: Int
        if let highlightedFieldID, let index = fields.firstIndex(where: { $0.id == highlightedFieldID }) {
            next = min(max(index + offset, 0), fields.count - 1)
        } else {
            next = offset > 0 ? 0 : fields.count - 1
        }
        highlightedFieldID = fields[next].id
        return .handled
    }

    private func copy(fieldID: String) {
        guard !copying, !store.isLocked else { return }
        let itemID = item.id
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
                  let field = store.quickCopyFields(for: item).first(where: { $0.id == fieldID }) else { return }
            Clipboard.copy(field.value)
            copiedFieldID = field.id
            copyNotice = L10n.format("%@ copied", field.isCustom ? field.title : L10n.string(field.title))
        }
    }
}

// MARK: - Unlock

private struct MacQuickUnlockView: View {
    @ObservedObject var store: AppStore
    @State private var password = ""
    @State private var unlocking = false
    @State private var failed = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vault Locked", systemImage: "lock.fill").font(.title3.bold())
            Button {
                unlock(biometrics: true)
            } label: {
                Label(L10n.format("Unlock with %@", BiometricAuthenticator.displayName), systemImage: BiometricAuthenticator.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit { unlock(biometrics: false) }
            if failed {
                Text("Couldn’t unlock. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
            if !success, !biometrics { passwordFocused = true }
        }
    }
}

// MARK: - Generator

private struct MacQuickGeneratorView: View {
    @State private var generated = ""
    @AppStorage(GeneratorPreferenceKey.length) private var length = 20.0
    @AppStorage(GeneratorPreferenceKey.uppercase) private var includesUppercase = true
    @AppStorage(GeneratorPreferenceKey.numbers) private var includesNumbers = true
    @AppStorage(GeneratorPreferenceKey.symbols) private var includesSymbols = true

    private var options: SecretGenerator.PasswordOptions {
        SecretGenerator.PasswordOptions(
            length: Int(length),
            includesUppercase: includesUppercase,
            includesNumbers: includesNumbers,
            includesSymbols: includesSymbols
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ColoredGeneratedValue(value: generated)
                .font(.title3.monospaced().weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            GeneratorStrengthLabel(strength: GeneratorStrength(bits: SecretGenerator.entropyBits(options)))
            PasswordOptionRows(
                length: $length,
                includesUppercase: $includesUppercase,
                includesNumbers: $includesNumbers,
                includesSymbols: $includesSymbols
            )
            HStack {
                Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
                Spacer()
                AnimatedCopyButton(value: generated, title: "Copy", accessibilityName: "generated value")
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: regenerate)
        .onChange(of: options) { _, _ in regenerate() }
    }

    private func regenerate() {
        generated = SecretGenerator.password(options)
    }
}
#endif
