import Foundation

/// Pure, testable generation rules shared by the Generator, the menu bar
/// extra and the Generate Password intent.
///
/// Every random choice goes through a `RandomNumberGenerator`. The default is
/// `SystemRandomNumberGenerator` (the system CSPRNG), and Swift's
/// `random(in:)` / `randomElement(using:)` draw without modulo bias.
nonisolated enum SecretGenerator {
    static let passwordLengthRange: ClosedRange<Int> = 8...64
    static let passphraseWordRange: ClosedRange<Int> = 3...10

    // Ambiguous glyphs (0 O 1 l I) are left out so a password can be read
    // back or typed from another screen.
    static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let symbols = Array("!@#$%^&*+-=_?")

    nonisolated struct PasswordOptions: Equatable, Sendable {
        var length = 20
        var includesUppercase = true
        var includesNumbers = true
        var includesSymbols = true

        var clampedLength: Int {
            min(max(length, SecretGenerator.passwordLengthRange.lowerBound), SecretGenerator.passwordLengthRange.upperBound)
        }

        /// Character classes in use. Lowercase letters are always included.
        var characterClasses: [[Character]] {
            var classes = [SecretGenerator.lowercase]
            if includesUppercase { classes.append(SecretGenerator.uppercase) }
            if includesNumbers { classes.append(SecretGenerator.digits) }
            if includesSymbols { classes.append(SecretGenerator.symbols) }
            return classes
        }
    }

    nonisolated struct PassphraseOptions: Equatable, Sendable {
        var wordCount = 4
        var separator = "-"
        var capitalizes = false
        var includesNumber = true

        var clampedWordCount: Int {
            min(max(wordCount, SecretGenerator.passphraseWordRange.lowerBound), SecretGenerator.passphraseWordRange.upperBound)
        }

        /// An empty separator would make word boundaries ambiguous and cost
        /// entropy, so it falls back to a hyphen.
        var effectiveSeparator: String { separator.isEmpty ? "-" : separator }
    }

    // MARK: Passwords

    static func password(_ options: PasswordOptions) -> String {
        var generator = SystemRandomNumberGenerator()
        return password(options, using: &generator)
    }

    /// Guarantees at least one character from every enabled class, then
    /// shuffles so the guaranteed characters can land anywhere.
    static func password<G: RandomNumberGenerator>(_ options: PasswordOptions, using generator: inout G) -> String {
        let classes = options.characterClasses
        let pool = classes.flatMap { $0 }
        let length = options.clampedLength
        var characters: [Character] = []
        characters.reserveCapacity(length)
        for characterClass in classes {
            if let character = characterClass.randomElement(using: &generator) {
                characters.append(character)
            }
        }
        while characters.count < length {
            if let character = pool.randomElement(using: &generator) {
                characters.append(character)
            }
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    // MARK: Passphrases

    static func passphrase(_ options: PassphraseOptions) -> String {
        var generator = SystemRandomNumberGenerator()
        return passphrase(options, using: &generator)
    }

    /// Words from the EFF Large Wordlist. "Include Number" appends one digit
    /// to a randomly chosen word, as Bitwarden does.
    static func passphrase<G: RandomNumberGenerator>(
        _ options: PassphraseOptions,
        wordList: [String] = PassphraseWordList.words,
        using generator: inout G
    ) -> String {
        guard !wordList.isEmpty else { return "" }
        var words = (0..<options.clampedWordCount).map { _ in
            wordList.randomElement(using: &generator) ?? wordList[0]
        }
        if options.capitalizes {
            words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        if options.includesNumber {
            let index = Int.random(in: words.indices, using: &generator)
            words[index] += String(Int.random(in: 0...9, using: &generator))
        }
        return words.joined(separator: options.effectiveSeparator)
    }

    // MARK: Usernames

    static func username() -> String {
        var generator = SystemRandomNumberGenerator()
        return username(using: &generator)
    }

    static func username<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let words = PassphraseWordList.words
        let first = words.randomElement(using: &generator) ?? "silent"
        let second = words.randomElement(using: &generator) ?? "orbit"
        return "\(first).\(second)\(Int.random(in: 10...99, using: &generator))"
    }

    // MARK: Strength

    /// Bits of entropy of the generation process, not of a single value.
    static func entropyBits(_ options: PasswordOptions) -> Double {
        let poolSize = options.characterClasses.reduce(0) { $0 + $1.count }
        return Double(options.clampedLength) * log2(Double(poolSize))
    }

    static func entropyBits(_ options: PassphraseOptions, wordListCount: Int = PassphraseWordList.words.count) -> Double {
        guard wordListCount > 1 else { return 0 }
        let count = options.clampedWordCount
        var bits = Double(count) * log2(Double(wordListCount))
        if options.includesNumber { bits += log2(10) + log2(Double(count)) }
        return bits
    }
}

/// A plain three-step rating. 64 bits resists offline guessing for any
/// realistic attacker; under 45 bits is reachable for a determined one.
nonisolated enum GeneratorStrength: Equatable, Sendable {
    case weak, good, strong

    init(bits: Double) {
        switch bits {
        case 64.0...: self = .strong
        case 45.0..<64.0: self = .good
        default: self = .weak
        }
    }

    var title: String {
        switch self {
        case .weak: L10n.string("Weak")
        case .good: L10n.string("Good")
        case .strong: L10n.string("Strong")
        }
    }
}

/// How each character of a generated value is colored, as in Passwords.
nonisolated enum GeneratedCharacterKind: Equatable, Sendable {
    case letter, digit, symbol

    init(_ character: Character) {
        if character.isNumber {
            self = .digit
        } else if character.isLetter {
            self = .letter
        } else {
            self = .symbol
        }
    }
}
