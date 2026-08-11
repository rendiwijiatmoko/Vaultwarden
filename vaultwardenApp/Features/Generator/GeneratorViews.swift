import SwiftUI

private enum GeneratorMode: String, CaseIterable, Identifiable {
    case password = "Password"
    case passphrase = "Passphrase"
    case username = "Username"
    var id: String { rawValue }
}

struct GeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: GeneratorMode = .password
    @State private var generated = ""
    @State private var length = 20.0
    @State private var useUppercase = true
    @State private var useNumbers = true
    @State private var useSymbols = true
    @State private var wordCount = 4
    @State private var separator = "-"
    @State private var capitalize = false
    @State private var includeNumber = true
    @State private var showingSave = false
    @State private var showingHistory = false
    @State private var history: [GeneratorHistoryRecord] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Picker("Generator type", selection: $mode) {
                        ForEach(GeneratorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    generatedCard

                    Group {
                        switch mode {
                        case .password: passwordOptions
                        case .passphrase: passphraseOptions
                        case .username: usernameOptions
                        }
                    }
                    .padding(18)
                    .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    HStack(spacing: 12) {
                        AnimatedCopyButton(
                            value: generated,
                            title: "Copy",
                            accessibilityName: "generated value",
                            onCopy: recordCurrent,
                            fillsWidth: true
                        )
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            recordCurrent()
                            showingSave = true
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(16)
            }
            .background(Color.vaultBackground)
            .navigationTitle("Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loadHistory()
                        showingHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .onAppear { regenerate() }
            .onChange(of: mode) { _, _ in regenerate() }
            .onChange(of: length) { _, _ in regenerate() }
            .onChange(of: useUppercase) { _, _ in regenerate() }
            .onChange(of: useNumbers) { _, _ in regenerate() }
            .onChange(of: useSymbols) { _, _ in regenerate() }
            .onChange(of: wordCount) { _, _ in regenerate() }
            .onChange(of: separator) { _, _ in regenerate() }
            .onChange(of: capitalize) { _, _ in regenerate() }
            .onChange(of: includeNumber) { _, _ in regenerate() }
            .sheet(isPresented: $showingSave) {
                AddEditVaultItemView(prefilledPassword: generated)
            }
            .sheet(isPresented: $showingHistory) {
                GeneratorHistoryView(records: $history)
            }
        }
    }

    private var generatedCard: some View {
        VStack(spacing: 18) {
            HStack {
                Text(mode.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                strengthLabel
            }
            ColoredGeneratedValue(value: generated)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.65)
                .lineLimit(3, reservesSpace: true)
                .frame(height: 78, alignment: .topLeading)
            HStack {
                Button { regenerate(recordCurrentValue: true) } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                Spacer()
                AnimatedCopyButton(
                    value: generated,
                    accessibilityName: "generated value",
                    onCopy: recordCurrent
                )
            }
            .font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                Text("Letters").foregroundStyle(.primary)
                Text("Numbers").foregroundStyle(Color.vaultCyan)
                Text("Symbols").foregroundStyle(.pink)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Color.vaultBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.vaultBlue.opacity(0.15), lineWidth: 1)
        }
    }

    @ViewBuilder private var strengthLabel: some View {
        if mode != .username {
            Label(strengthText, systemImage: "shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(strengthColor)
        }
    }

    private var passwordOptions: some View {
        VStack(spacing: 17) {
            HStack {
                Text("Length")
                Spacer()
                Text(Int(length), format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $length, in: 8...64, step: 1)
            Divider()
            Toggle("Uppercase", isOn: $useUppercase)
            Toggle("Numbers", isOn: $useNumbers)
            Toggle("Symbols", isOn: $useSymbols)
            Label("Ambiguous characters such as 0, O, 1 and l are excluded.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var passphraseOptions: some View {
        VStack(spacing: 17) {
            Stepper("Words: \(wordCount)", value: $wordCount, in: 3...8)
            HStack {
                Text("Separator")
                Spacer()
                TextField("-", text: $separator)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Capitalize words", isOn: $capitalize)
            Toggle("Include number", isOn: $includeNumber)
        }
    }

    private var usernameOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Random username", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
            Text("Creates a private, non-identifying username. Email aliases can be added later through a supported alias provider.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Generate Another Username") { regenerate() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var strengthText: String {
        if mode == .passphrase { return wordCount >= 5 ? "Strong" : "Good" }
        if length >= 20 && useNumbers && useSymbols { return "Strong" }
        if length >= 14 { return "Good" }
        return "Weak"
    }

    private var strengthColor: Color {
        strengthText == "Strong" ? .vaultGreen : strengthText == "Good" ? .vaultYellow : .vaultRed
    }

    private func regenerate(recordCurrentValue: Bool = false) {
        if recordCurrentValue { recordCurrent() }
        switch mode {
        case .password:
            generated = PasswordGenerator.password(length: Int(length), uppercase: useUppercase, numbers: useNumbers, symbols: useSymbols)
        case .passphrase:
            generated = PasswordGenerator.passphrase(wordCount: wordCount, separator: separator.isEmpty ? "-" : separator, capitalize: capitalize, includeNumber: includeNumber)
        case .username:
            generated = PasswordGenerator.username()
        }
    }

    private func recordCurrent() {
        try? GeneratorHistoryStore.add(value: generated, kind: mode.rawValue)
        loadHistory()
    }

    private func loadHistory() {
        history = (try? GeneratorHistoryStore.load()) ?? []
    }

}

private struct ColoredGeneratedValue: View {
    let value: String

    var body: some View {
        Text(attributedValue)
    }

    private var attributedValue: AttributedString {
        var result = AttributedString()
        for character in value {
            var segment = AttributedString(String(character))
            if character.isNumber {
                segment.foregroundColor = .vaultCyan
            } else if character.isLetter {
                segment.foregroundColor = .primary
            } else {
                segment.foregroundColor = .pink
            }
            result.append(segment)
        }
        return result
    }
}

private struct GeneratorHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var records: [GeneratorHistoryRecord]
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No Generator History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Values you copy, save, or replace with Regenerate will appear here.")
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(record.kind)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(record.createdAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                HStack(spacing: 10) {
                                    ColoredGeneratedValue(value: record.value)
                                        .font(.body.monospaced().weight(.semibold))
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    AnimatedCopyButton(
                                        value: record.value,
                                        accessibilityName: "generated history value"
                                    )
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 5)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    try? GeneratorHistoryStore.delete(id: record.id)
                                    reload()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Generator History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear generator history")
                        .confirmationDialog(
                            "Clear generator history?",
                            isPresented: $confirmClear,
                            titleVisibility: .visible
                        ) {
                            Button("Clear History", role: .destructive) {
                                try? GeneratorHistoryStore.clear()
                                reload()
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("All generated values stored on this device will be removed.")
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        records = (try? GeneratorHistoryStore.load()) ?? []
    }
}

struct QuickPasswordGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var generated = PasswordGenerator.password(length: 20, uppercase: true, numbers: true, symbols: true)
    @State private var length = 20.0
    @State private var useUppercase = true
    @State private var useNumbers = true
    @State private var useSymbols = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ColoredGeneratedValue(value: generated)
                        .font(.title2.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .minimumScaleFactor(0.65)
                        .lineLimit(3, reservesSpace: true)
                        .frame(height: 78, alignment: .topLeading)
                        .padding(18)
                        .background(Color.vaultBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                    VStack(spacing: 17) {
                        HStack {
                            Text("Length")
                            Spacer()
                            Text(Int(length), format: .number)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $length, in: 8...64, step: 1)
                        Divider()
                        Toggle("Uppercase", isOn: $useUppercase)
                        Toggle("Numbers", isOn: $useNumbers)
                        Toggle("Symbols", isOn: $useSymbols)
                    }
                    .padding(18)
                    .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Button {
                        regenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.vaultBlue)

                    Button {
                        onUse(generated)
                    } label: {
                        Text("Use This Password")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .background(Color.vaultBackground)
            .navigationTitle("Generate Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: length) { _, _ in regenerate() }
            .onChange(of: useUppercase) { _, _ in regenerate() }
            .onChange(of: useNumbers) { _, _ in regenerate() }
            .onChange(of: useSymbols) { _, _ in regenerate() }
        }
        .presentationDetents([.large])
    }

    private func regenerate() {
        generated = PasswordGenerator.password(
            length: Int(length),
            uppercase: useUppercase,
            numbers: useNumbers,
            symbols: useSymbols
        )
    }
}

struct QuickUsernameGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String) -> Void
    @State private var generated = PasswordGenerator.username()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ColoredGeneratedValue(value: generated)
                    .font(.title2.monospaced().weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color.vaultBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    generated = PasswordGenerator.username()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.vaultBlue)

                Button {
                    onUse(generated)
                } label: {
                    Text("Use This Username")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Generate Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
