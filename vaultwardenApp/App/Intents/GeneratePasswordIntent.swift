import AppIntents
import SwiftUI

nonisolated enum GeneratedSecretKind: String, AppEnum {
    case password
    case passphrase

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Password Type" }

    static var caseDisplayRepresentations: [GeneratedSecretKind: DisplayRepresentation] {
        [
            .password: "Password",
            .passphrase: "Passphrase"
        ]
    }
}

/// Runs without opening the app and needs no vault: it only draws random
/// characters. The value goes to Shortcuts or Siri and nowhere else; it is not
/// added to the generator history, which belongs to the unlocked app.
nonisolated struct GeneratePasswordIntent: AppIntent {
    static var title: LocalizedStringResource { "Generate Password" }
    static var description: IntentDescription {
        IntentDescription("Creates a random password or passphrase.")
    }
    static var openAppWhenRun: Bool { false }

    // App Intents reads these defaults and ranges at build time, so they must
    // be literals. They match SecretGenerator's ranges and the app's defaults.
    @Parameter(title: "Type", default: .password)
    var kind: GeneratedSecretKind

    @Parameter(title: "Length", default: 20, inclusiveRange: (8, 64))
    var length: Int

    @Parameter(title: "Words", default: 4, inclusiveRange: (3, 10))
    var wordCount: Int

    @Parameter(title: "Uppercase", default: true)
    var includesUppercase: Bool

    @Parameter(title: "Numbers", default: true)
    var includesNumbers: Bool

    @Parameter(title: "Symbols", default: true)
    var includesSymbols: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Generate \(\.$kind)") {
            \.$length
            \.$wordCount
            \.$includesUppercase
            \.$includesNumbers
            \.$includesSymbols
        }
    }

    /// Pure so tests can check the options without the App Intents runtime.
    static func generate(
        kind: GeneratedSecretKind,
        length: Int,
        wordCount: Int,
        includesUppercase: Bool,
        includesNumbers: Bool,
        includesSymbols: Bool
    ) -> String {
        switch kind {
        case .password:
            SecretGenerator.password(SecretGenerator.PasswordOptions(
                length: length,
                includesUppercase: includesUppercase,
                includesNumbers: includesNumbers,
                includesSymbols: includesSymbols
            ))
        case .passphrase:
            SecretGenerator.passphrase(SecretGenerator.PassphraseOptions(
                wordCount: wordCount,
                separator: "-",
                capitalizes: includesUppercase,
                includesNumber: includesNumbers
            ))
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let value = Self.generate(
            kind: kind,
            length: length,
            wordCount: wordCount,
            includesUppercase: includesUppercase,
            includesNumbers: includesNumbers,
            includesSymbols: includesSymbols
        )
        // Siri speaks the dialog, so it never contains the value itself.
        let dialog: IntentDialog = kind == .password ? "Here’s a new password." : "Here’s a new passphrase."
        return .result(value: value, dialog: dialog, view: GeneratedSecretSnippet(value: value))
    }
}

/// Shown by Siri and Shortcuts. Static, because snippets can't be interacted
/// with beyond what the system provides.
struct GeneratedSecretSnippet: View {
    let value: String

    var body: some View {
        ColoredGeneratedValue(value: value)
            .font(.title3.monospaced().weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
    }
}
