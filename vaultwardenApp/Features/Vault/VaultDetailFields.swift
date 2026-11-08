import SwiftUI

/// A field on an item's page. Tap (or click) copies it and its label says
/// "Copied" for a moment. Secrets stay masked until revealed, and revealing or
/// copying them follows "Authenticate before reveal or copy".
struct VaultDetailField: View {
    let title: String
    let value: String
    /// Shown instead of `value` when set, for example a card number's last four.
    var displayValue: String?
    var isSecret = false
    var isMonospaced = false
    /// False for values that are shown but must not be copied or revealed.
    var allowsAccess = true

    @EnvironmentObject private var store: AppStore
    @State private var isRevealed = false
    @State private var showsCopied = false
    @State private var copyCount = 0
    #if os(macOS)
    @State private var isHovering = false
    #endif

    /// A fixed run of dots, so the mask doesn't give away the length.
    static let mask = String(repeating: "•", count: 10)

    private var shownValue: String {
        if isSecret && !(isRevealed && allowsAccess) { return Self.mask }
        return displayValue ?? value
    }

    private var label: String {
        showsCopied ? L10n.string("Copied") : title
    }

    var body: some View {
        #if os(macOS)
        MacDetailRow(title: label, isHighlighted: showsCopied) {
            HStack(spacing: 8) {
                Text(shownValue)
                    .font(isSecret || isMonospaced ? .body.monospaced() : .body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isSecret, allowsAccess {
                    revealButton
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
        .background(isHovering && allowsAccess ? Color.primary.opacity(0.04) : .clear, in: .rect(cornerRadius: 6))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.13)) { isHovering = hovering }
        }
        .onTapGesture { copy() }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.format("Copy %@", title))) { copy() }
        .help(allowsAccess ? L10n.format("Copy %@", title) : "")
        .contextMenu { menu }
        .vaultHaptic(.success, trigger: copyCount)
        #else
        HStack(spacing: 8) {
            Button(action: copy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(showsCopied ? Color.accentColor : Color.secondary)
                    Text(shownValue)
                        .font(isSecret || isMonospaced ? .body.monospaced() : .body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!allowsAccess)
            .accessibilityHint(allowsAccess ? L10n.string("Copies the value") : "")

            if isSecret, allowsAccess {
                revealButton
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .contextMenu { menu }
        .vaultHaptic(.success, trigger: copyCount)
        #endif
    }

    private var revealButton: some View {
        Button(action: toggleReveal) {
            Label(isRevealed ? L10n.string("Hide") : L10n.string("Show"),
                  systemImage: isRevealed ? "eye.slash" : "eye")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(isRevealed ? L10n.string("Hide") : L10n.string("Show"))
    }

    @ViewBuilder
    private var menu: some View {
        if allowsAccess, !value.isEmpty {
            Button(L10n.format("Copy %@", title), systemImage: "doc.on.doc", action: copy)
            if isSecret {
                Button(isRevealed ? L10n.string("Hide") : L10n.string("Show"),
                       systemImage: isRevealed ? "eye.slash" : "eye",
                       action: toggleReveal)
            }
        }
    }

    private func toggleReveal() {
        if isRevealed {
            isRevealed = false
            return
        }
        Task {
            guard await VaultSensitiveAccess.authorize(store) else { return }
            isRevealed = true
        }
    }

    private func copy() {
        guard allowsAccess, !value.isEmpty else { return }
        Task {
            if isSecret {
                guard await VaultSensitiveAccess.authorize(store) else { return }
            }
            Clipboard.copy(value)
            copyCount += 1
            let current = copyCount
            withAnimation(VaultMotion.fade) { showsCopied = true }
            try? await Task.sleep(for: .seconds(1.5))
            guard current == copyCount else { return }
            withAnimation(VaultMotion.fade) { showsCopied = false }
        }
    }
}

/// A website on an item's page: tap copies, the trailing button opens it.
struct VaultWebsiteField: View {
    let title: String
    let uri: String
    let url: URL?

    var body: some View {
        HStack(spacing: 8) {
            VaultDetailField(title: title, value: uri, displayValue: WebsiteIconHost.displayHost(for: uri) ?? uri)
            if let url {
                Link(destination: url) {
                    Label("Open Website", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Open Website"))
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
            }
        }
    }
}

struct CustomFieldDetailRow: View {
    let field: VaultCustomField
    let item: VaultItem
    let canRevealSecrets: Bool

    private var resolvedValue: String {
        guard field.type == .linked else { return field.value }
        return field.value == "password" ? item.password : item.username
    }

    var body: some View {
        switch field.type {
        case .boolean:
            LabeledContent(field.name) {
                Image(systemName: field.value == "true" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(field.value == "true" ? Color.green : .secondary)
                    .accessibilityLabel(field.value == "true" ? L10n.string("On") : L10n.string("Off"))
            }
        case .hidden:
            VaultDetailField(title: field.name, value: resolvedValue, isSecret: true, allowsAccess: canRevealSecrets)
        case .linked where field.value == "password":
            VaultDetailField(title: field.name, value: resolvedValue, isSecret: true, allowsAccess: canRevealSecrets)
        case .text, .linked:
            VaultDetailField(title: field.name, value: resolvedValue)
        }
    }
}

struct PasswordHistoryRow: View {
    let entry: VaultPasswordHistoryEntry
    let canRevealSecrets: Bool

    var body: some View {
        VaultDetailField(
            title: entry.lastUsedDate.formatted(date: .abbreviated, time: .shortened),
            value: entry.password,
            isSecret: true,
            allowsAccess: canRevealSecrets
        )
        .id(entry)
    }
}

/// Checks the password against known data leaks with k-anonymity: only the first
/// five characters of its SHA-1 hash leave the device.
struct PasswordBreachCheck: View {
    let password: String
    @State private var state: BreachCheckState = .idle

    private enum BreachCheckState: Equatable {
        case idle, checking, safe, exposed(Int), failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: check) {
                HStack(spacing: 8) {
                    if state == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Text(state == .checking ? L10n.string("Checking…") : L10n.string("Check for Data Leaks"))
                }
            }
            .buttonStyle(.borderless)
            .disabled(password.isEmpty || state == .checking)

            switch state {
            case .safe:
                Label("Not found in known data leaks.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            case let .exposed(count):
                Label(
                    L10n.format("Found in data leaks %@ times. Change this password.", count.formatted()),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            case .failed:
                Label("Couldn’t check. Try again when you’re online.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            case .idle, .checking:
                EmptyView()
            }
        }
        .font(.subheadline)
        .animation(VaultMotion.fade, value: state)
    }

    private func check() {
        guard !password.isEmpty, state != .checking else { return }
        state = .checking
        Task {
            do {
                switch try await PasswordBreachChecker.check(password) {
                case .notFound: state = .safe
                case let .exposed(count): state = .exposed(count)
                }
            } catch {
                state = .failed
            }
        }
    }
}

#if os(macOS)
struct MacDetailCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.background, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}

/// A label on the left and its value on the right, as on Mac Passwords' item page.
struct MacDetailRow<Content: View>: View {
    let title: String
    var isHighlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
                .frame(minWidth: 110, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}
#endif
