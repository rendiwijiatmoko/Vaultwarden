import SwiftUI

private enum GeneratorMode: String, CaseIterable, Identifiable {
    case password = "Password"
    case passphrase = "Passphrase"
    case username = "Username"
    case sshKey = "SSH Key"
    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }

    var copyTitle: String {
        switch self {
        case .password: "Copy Password"
        case .passphrase: "Copy Passphrase"
        case .username: "Copy Username"
        case .sshKey: "Copy"
        }
    }
}

/// Where the generator lives. The Mac also opens it as its own window from
/// Vault > Generator, where it has no Close button of its own.
enum GeneratorPresentation {
    case sheet, window
}

/// Generator options are preferences, not secrets, so they persist and the
/// generator opens the way the person left it.
enum GeneratorPreferenceKey {
    static let length = "generator.passwordLength"
    static let uppercase = "generator.uppercase"
    static let numbers = "generator.numbers"
    static let symbols = "generator.symbols"
    static let wordCount = "generator.wordCount"
    static let separator = "generator.separator"
    static let capitalize = "generator.capitalize"
    static let includeNumber = "generator.includeNumber"
}

struct GeneratorView: View {
    var presentation: GeneratorPresentation = .sheet
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var sshPrivateKey = ""
    @State private var sshPublicKey = ""
    @State private var sshFingerprint = ""
    @State private var mode: GeneratorMode = .password
    @State private var generated = ""
    @State private var regenerateCount = 0
    @State private var showingSave = false
    @State private var showingHistory = false
    @State private var history: [GeneratorHistoryRecord] = []
    @AppStorage(GeneratorPreferenceKey.length) private var length = 20.0
    @AppStorage(GeneratorPreferenceKey.uppercase) private var includesUppercase = true
    @AppStorage(GeneratorPreferenceKey.numbers) private var includesNumbers = true
    @AppStorage(GeneratorPreferenceKey.symbols) private var includesSymbols = true
    @AppStorage(GeneratorPreferenceKey.wordCount) private var wordCount = 4
    @AppStorage(GeneratorPreferenceKey.separator) private var separator = "-"
    @AppStorage(GeneratorPreferenceKey.capitalize) private var capitalizes = false
    @AppStorage(GeneratorPreferenceKey.includeNumber) private var includesNumber = true

    private var isVaultAvailable: Bool { store.isAuthenticated && !store.isLocked }

    private var passwordOptions: SecretGenerator.PasswordOptions {
        SecretGenerator.PasswordOptions(
            length: Int(length),
            includesUppercase: includesUppercase,
            includesNumbers: includesNumbers,
            includesSymbols: includesSymbols
        )
    }

    private var passphraseOptions: SecretGenerator.PassphraseOptions {
        SecretGenerator.PassphraseOptions(
            wordCount: wordCount,
            separator: separator,
            capitalizes: capitalizes,
            includesNumber: includesNumber
        )
    }

    private var strength: GeneratorStrength? {
        switch mode {
        case .password: GeneratorStrength(bits: SecretGenerator.entropyBits(passwordOptions))
        case .passphrase: GeneratorStrength(bits: SecretGenerator.entropyBits(passphraseOptions))
        case .username, .sshKey: nil
        }
    }

    var body: some View {
        content
            .onAppear { regenerate() }
            .onChange(of: mode) { _, _ in
                clearSSHKey()
                regenerate()
            }
            .onChange(of: passwordOptions) { _, _ in if mode == .password { regenerate() } }
            .onChange(of: passphraseOptions) { _, _ in if mode == .passphrase { regenerate() } }
            .onChange(of: store.isLocked) { _, locked in
                if locked {
                    clearSSHKey()
                    showingSave = false
                    showingHistory = false
                    history = []
                }
            }
            .onChange(of: store.authenticatedSession?.tokenReference) { _, _ in
                clearSSHKey()
                showingSave = false
                showingHistory = false
            }
            .onDisappear { clearSSHKey() }
            .sensoryFeedback(trigger: regenerateCount) { _, _ in
                store.settings.haptics ? .impact(weight: .light) : nil
            }
            .sheet(isPresented: $showingSave) {
                Group {
                    if mode == .sshKey {
                        AddEditVaultItemView(
                            prefilledPassword: sshPrivateKey,
                            prefilledUsername: sshPublicKey,
                            prefilledSSHFingerprint: sshFingerprint,
                            prefilledType: .sshKey
                        )
                    } else if mode == .username {
                        AddEditVaultItemView(prefilledUsername: generated, prefilledType: .login)
                    } else {
                        AddEditVaultItemView(prefilledPassword: generated)
                    }
                }
                .environmentObject(store)
            }
    }

    // MARK: Layout

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            if presentation == .sheet {
                Text("Generator")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 20)
            }
            form
            Divider()
            HStack(spacing: 8) {
                if mode != .sshKey && isVaultAvailable {
                    Button("History", systemImage: "clock.arrow.circlepath") {
                        loadHistory()
                        showingHistory = true
                    }
                    .help("History")
                    .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                        GeneratorHistoryList(records: $history)
                            .frame(width: 380, height: 420)
                    }
                }
                Spacer()
                if presentation == .sheet {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                saveButton
                if mode != .sshKey {
                    copyButton
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
    }
    #else
    private var content: some View {
        NavigationStack {
            form
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        saveButton
                            .buttonStyle(.bordered)
                        if mode != .sshKey {
                            copyButton
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                .navigationTitle("Generator")
                .vaultNavigationTitleDisplayMode(.inline)
                .toolbar {
                    if presentation == .sheet {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
                    if mode != .sshKey && isVaultAvailable {
                        ToolbarItem(placement: .vaultTrailing) {
                            Button("History", systemImage: "clock.arrow.circlepath") {
                                loadHistory()
                                showingHistory = true
                            }
                        }
                    }
                }
                .navigationDestination(isPresented: $showingHistory) {
                    GeneratorHistoryList(records: $history)
                }
        }
    }
    #endif

    private var form: some View {
        Form {
            Section {
                Picker("Type", selection: $mode) {
                    ForEach(GeneratorMode.allCases) { Text($0.localizedTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(iOS)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                #endif
            }

            if mode == .sshKey {
                Section {
                    SSHKeyGeneratorFields(
                        privateKey: $sshPrivateKey,
                        publicKey: $sshPublicKey,
                        fingerprint: $sshFingerprint
                    )
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    generatedValue
                }

                switch mode {
                case .password:
                    Section {
                        PasswordOptionRows(
                            length: $length,
                            includesUppercase: $includesUppercase,
                            includesNumbers: $includesNumbers,
                            includesSymbols: $includesSymbols
                        )
                    }
                case .passphrase:
                    Section {
                        PassphraseOptionRows(
                            wordCount: $wordCount,
                            separator: $separator,
                            capitalizes: $capitalizes,
                            includesNumber: $includesNumber
                        )
                    }
                case .username, .sshKey:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var generatedValue: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColoredGeneratedValue(value: generated)
                .font(valueFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let strength {
                    GeneratorStrengthLabel(strength: strength)
                }
                Spacer()
                Button {
                    regenerate(recordCurrentValue: true)
                    regenerateCount += 1
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .symbolEffect(.rotate, value: regenerateCount)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Regenerate")
            }
        }
        .padding(.vertical, 4)
    }

    private var valueFont: Font {
        #if os(macOS)
        .title.monospaced().weight(.medium)
        #else
        .title2.monospaced().weight(.medium)
        #endif
    }

    private var copyButton: some View {
        AnimatedCopyButton(
            value: generated,
            title: mode.copyTitle,
            accessibilityName: "generated value",
            onCopy: recordCurrent,
            fillsWidth: platformFillsWidth
        )
        .disabled(generated.isEmpty)
    }

    private var saveButton: some View {
        Button {
            recordCurrent()
            showingSave = true
        } label: {
            Text("Save to Vault…")
                .frame(maxWidth: platformFillsWidth ? .infinity : nil)
        }
        .disabled(!isVaultAvailable || (mode == .sshKey && sshPrivateKey.isEmpty))
    }

    private var platformFillsWidth: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    // MARK: Actions

    private func regenerate(recordCurrentValue: Bool = false) {
        if recordCurrentValue { recordCurrent() }
        switch mode {
        case .password:
            generated = SecretGenerator.password(passwordOptions)
        case .passphrase:
            generated = SecretGenerator.passphrase(passphraseOptions)
        case .username:
            generated = SecretGenerator.username()
        case .sshKey:
            generated = ""
        }
    }

    private func clearSSHKey() {
        sshPrivateKey = ""
        sshPublicKey = ""
        sshFingerprint = ""
    }

    private func recordCurrent() {
        guard mode != .sshKey, !generated.isEmpty else { return }
        try? GeneratorHistoryStore.add(value: generated, kind: mode.rawValue)
        if showingHistory { loadHistory() }
    }

    private func loadHistory() {
        history = (try? GeneratorHistoryStore.load()) ?? []
    }
}

// MARK: - Option rows

/// Length, then the character classes. Lowercase letters are always used.
struct PasswordOptionRows: View {
    @Binding var length: Double
    @Binding var includesUppercase: Bool
    @Binding var includesNumbers: Bool
    @Binding var includesSymbols: Bool

    private var range: ClosedRange<Double> {
        Double(SecretGenerator.passwordLengthRange.lowerBound)...Double(SecretGenerator.passwordLengthRange.upperBound)
    }

    var body: some View {
        LabeledContent("Length") {
            HStack(spacing: 8) {
                Text(Int(length), format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("Length", value: $length, in: range, step: 1)
                    .labelsHidden()
            }
        }
        Slider(value: $length, in: range, step: 1) {
            Text("Length")
        }
        .labelsHidden()
        Toggle("Uppercase", isOn: $includesUppercase)
        Toggle("Numbers", isOn: $includesNumbers)
        Toggle("Symbols", isOn: $includesSymbols)
    }
}

struct PassphraseOptionRows: View {
    @Binding var wordCount: Int
    @Binding var separator: String
    @Binding var capitalizes: Bool
    @Binding var includesNumber: Bool

    var body: some View {
        LabeledContent("Words") {
            HStack(spacing: 8) {
                Text(wordCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("Words", value: $wordCount, in: SecretGenerator.passphraseWordRange)
                    .labelsHidden()
            }
        }
        LabeledContent("Separator") {
            TextField("Separator", text: $separator, prompt: Text(verbatim: "-"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .vaultTextInputAutocapitalization(.never)
                .frame(maxWidth: 80)
                .onChange(of: separator) { _, newValue in
                    if newValue.count > 3 { separator = String(newValue.prefix(3)) }
                }
        }
        Toggle("Capitalize", isOn: $capitalizes)
        Toggle("Include Number", isOn: $includesNumber)
    }
}

struct GeneratorStrengthLabel: View {
    let strength: GeneratorStrength

    var body: some View {
        Label {
            Text(strength.title)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.subheadline.weight(.medium))
    }

    private var symbol: String {
        switch strength {
        case .weak: "exclamationmark.shield.fill"
        case .good: "shield.lefthalf.filled"
        case .strong: "checkmark.shield.fill"
        }
    }

    private var color: Color {
        switch strength {
        case .weak: .vaultRed
        case .good: .vaultOrange
        case .strong: .vaultGreen
        }
    }
}

/// Letters in the primary color, digits and symbols tinted, as Passwords
/// shows suggested passwords. VoiceOver spells the value out.
struct ColoredGeneratedValue: View {
    let value: String

    var body: some View {
        Text(attributedValue)
            .speechSpellsOutCharacters()
    }

    private var attributedValue: AttributedString {
        var result = AttributedString()
        for character in value {
            var segment = AttributedString(String(character))
            switch GeneratedCharacterKind(character) {
            case .letter: segment.foregroundColor = .primary
            case .digit: segment.foregroundColor = .vaultCyan
            case .symbol: segment.foregroundColor = .pink
            }
            result.append(segment)
        }
        return result
    }
}

// MARK: - History

private struct GeneratorHistoryList: View {
    @Binding var records: [GeneratorHistoryRecord]
    @State private var confirmClear = false

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath")
            } else {
                List {
                    ForEach(records) { record in
                        GeneratorHistoryRow(record: record) { delete(record) }
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !records.isEmpty {
                    Button("Clear…") { confirmClear = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        #else
        .navigationTitle("History")
        .vaultNavigationTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .vaultTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        #endif
        .confirmationDialog("Clear Generator History?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button(role: .destructive) {
                try? GeneratorHistoryStore.clear()
                reload()
            } label: {
                Text("Delete ^[\(records.count) Item](inflect: true)")
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func delete(_ record: GeneratorHistoryRecord) {
        try? GeneratorHistoryStore.delete(id: record.id)
        reload()
    }

    private func reload() {
        records = (try? GeneratorHistoryStore.load()) ?? []
    }
}

private struct GeneratorHistoryRow: View {
    let record: GeneratorHistoryRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ColoredGeneratedValue(value: record.value)
                    .font(.body.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(L10n.string(record.kind))
                    Text(verbatim: "·")
                    Text(record.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            AnimatedCopyButton(value: record.value, accessibilityName: "generated history value")
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(record.value) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Editor generators

/// Opened from a login's password field. Shares the generator's remembered
/// options, so a suggestion here matches the full generator.
struct QuickPasswordGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var usesPassphrase = false
    @State private var generated = ""
    @AppStorage(GeneratorPreferenceKey.length) private var length = 20.0
    @AppStorage(GeneratorPreferenceKey.uppercase) private var includesUppercase = true
    @AppStorage(GeneratorPreferenceKey.numbers) private var includesNumbers = true
    @AppStorage(GeneratorPreferenceKey.symbols) private var includesSymbols = true
    @AppStorage(GeneratorPreferenceKey.wordCount) private var wordCount = 4
    @AppStorage(GeneratorPreferenceKey.separator) private var separator = "-"
    @AppStorage(GeneratorPreferenceKey.capitalize) private var capitalizes = false
    @AppStorage(GeneratorPreferenceKey.includeNumber) private var includesNumber = true

    private var passwordOptions: SecretGenerator.PasswordOptions {
        SecretGenerator.PasswordOptions(
            length: Int(length),
            includesUppercase: includesUppercase,
            includesNumbers: includesNumbers,
            includesSymbols: includesSymbols
        )
    }

    private var passphraseOptions: SecretGenerator.PassphraseOptions {
        SecretGenerator.PassphraseOptions(
            wordCount: wordCount,
            separator: separator,
            capitalizes: capitalizes,
            includesNumber: includesNumber
        )
    }

    private var strength: GeneratorStrength {
        GeneratorStrength(bits: usesPassphrase
            ? SecretGenerator.entropyBits(passphraseOptions)
            : SecretGenerator.entropyBits(passwordOptions))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $usesPassphrase) {
                        Text("Password").tag(false)
                        Text("Passphrase").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    #if os(iOS)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    #endif
                }
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ColoredGeneratedValue(value: generated)
                            .font(.title2.monospaced().weight(.medium))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            GeneratorStrengthLabel(strength: strength)
                            Spacer()
                            Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .frame(minWidth: 28, minHeight: 28)
                                .help("Regenerate")
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if usesPassphrase {
                        PassphraseOptionRows(
                            wordCount: $wordCount,
                            separator: $separator,
                            capitalizes: $capitalizes,
                            includesNumber: $includesNumber
                        )
                    } else {
                        PasswordOptionRows(
                            length: $length,
                            includesUppercase: $includesUppercase,
                            includesNumbers: $includesNumbers,
                            includesSymbols: $includesSymbols
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(usesPassphrase ? "Generate Passphrase" : "Generate Password")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { onUse(generated) }
                        .disabled(generated.isEmpty)
                }
            }
            .onAppear(perform: regenerate)
            .onChange(of: usesPassphrase) { _, _ in regenerate() }
            .onChange(of: passwordOptions) { _, _ in if !usesPassphrase { regenerate() } }
            .onChange(of: passphraseOptions) { _, _ in if usesPassphrase { regenerate() } }
        }
        .presentationDetents([.large])
        .vaultSheetSize(width: 520, height: 560)
    }

    private func regenerate() {
        generated = usesPassphrase
            ? SecretGenerator.passphrase(passphraseOptions)
            : SecretGenerator.password(passwordOptions)
    }
}

struct QuickUsernameGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var generated = SecretGenerator.username()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ColoredGeneratedValue(value: generated)
                            .font(.title3.monospaced().weight(.medium))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Regenerate", systemImage: "arrow.clockwise") {
                            generated = SecretGenerator.username()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .frame(minWidth: 28, minHeight: 28)
                        .help("Regenerate")
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Generate Username")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { onUse(generated) }
                }
            }
        }
        .presentationDetents([.medium])
        .vaultSheetSize(width: 460, height: 220)
    }
}
