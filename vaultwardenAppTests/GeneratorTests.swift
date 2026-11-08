import Foundation
import Testing
@testable import vaultwardenApp

/// Deterministic, so a failing case reproduces. Not for production use.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Secret generator")
struct GeneratorTests {
    @Test("Every enabled class appears, disabled classes never do", arguments: [
        (false, false, false), (true, false, false), (false, true, false), (false, false, true),
        (true, true, false), (true, false, true), (false, true, true), (true, true, true)
    ])
    func characterClassGuarantees(uppercase: Bool, numbers: Bool, symbols: Bool) {
        var generator = SplitMix64(state: 42)
        let options = SecretGenerator.PasswordOptions(
            length: 8,
            includesUppercase: uppercase,
            includesNumbers: numbers,
            includesSymbols: symbols
        )
        for _ in 0..<300 {
            let value = SecretGenerator.password(options, using: &generator)
            #expect(value.contains { SecretGenerator.lowercase.contains($0) })
            #expect(value.contains { SecretGenerator.uppercase.contains($0) } == uppercase)
            #expect(value.contains { SecretGenerator.digits.contains($0) } == numbers)
            #expect(value.contains { SecretGenerator.symbols.contains($0) } == symbols)
        }
    }

    @Test("Length is clamped to the supported range", arguments: [
        (-5, 8), (0, 8), (7, 8), (8, 8), (20, 20), (64, 64), (65, 64), (1_000, 64)
    ])
    func lengthBounds(requested: Int, expected: Int) {
        let options = SecretGenerator.PasswordOptions(length: requested)
        #expect(SecretGenerator.password(options).count == expected)
    }

    @Test func passwordsLeaveOutLookAlikeCharacters() {
        var generator = SplitMix64(state: 7)
        let options = SecretGenerator.PasswordOptions(length: 64)
        let combined = (0..<50).map { _ in SecretGenerator.password(options, using: &generator) }.joined()
        #expect(!combined.contains { "0O1lI".contains($0) })
    }

    @Test func passwordsDifferBetweenCalls() {
        let options = SecretGenerator.PasswordOptions()
        let values = Set((0..<20).map { _ in SecretGenerator.password(options) })
        #expect(values.count == 20)
    }

    @Test("Word count is clamped", arguments: [(1, 3), (3, 3), (6, 6), (10, 10), (50, 10)])
    func passphraseWordBounds(requested: Int, expected: Int) {
        var generator = SplitMix64(state: 3)
        let options = SecretGenerator.PassphraseOptions(wordCount: requested, separator: "_", includesNumber: false)
        let value = SecretGenerator.passphrase(options, using: &generator)
        #expect(value.split(separator: "_").count == expected)
    }

    @Test func passphraseNumberAndCapitalization() {
        var generator = SplitMix64(state: 11)
        let options = SecretGenerator.PassphraseOptions(wordCount: 5, separator: " ", capitalizes: true, includesNumber: true)
        for _ in 0..<100 {
            let words = SecretGenerator.passphrase(options, using: &generator).split(separator: " ")
            #expect(words.count == 5)
            #expect(words.allSatisfy { $0.first?.isUppercase == true })
            #expect(words.filter { $0.last?.isNumber == true }.count == 1)
        }
    }

    @Test func emptySeparatorFallsBackToHyphen() {
        let options = SecretGenerator.PassphraseOptions(wordCount: 4, separator: "", includesNumber: false)
        #expect(SecretGenerator.passphrase(options).split(separator: "-").count == 4)
    }

    @Test func wordListIsLargeUniqueAndPlain() {
        let words = PassphraseWordList.words
        #expect(words.count == 7_772)
        #expect(Set(words).count == words.count)
        #expect(words.allSatisfy { word in !word.isEmpty && word.allSatisfy { $0.isLetter && $0.isLowercase } })
    }

    @Test func entropyDrivesStrength() {
        // 8 lowercase letters is about 37 bits.
        #expect(GeneratorStrength(bits: SecretGenerator.entropyBits(SecretGenerator.PasswordOptions(
            length: 8, includesUppercase: false, includesNumbers: false, includesSymbols: false
        ))) == .weak)
        #expect(GeneratorStrength(bits: SecretGenerator.entropyBits(SecretGenerator.PasswordOptions())) == .strong)
        // Four EFF words is about 52 bits; five is about 65.
        #expect(GeneratorStrength(bits: SecretGenerator.entropyBits(SecretGenerator.PassphraseOptions(
            wordCount: 4, includesNumber: false
        ))) == .good)
        #expect(GeneratorStrength(bits: SecretGenerator.entropyBits(SecretGenerator.PassphraseOptions(
            wordCount: 5, includesNumber: false
        ))) == .strong)
    }

    @Test("Characters are colored by kind", arguments: [
        (Character("a"), GeneratedCharacterKind.letter),
        ("Z", .letter),
        ("7", .digit),
        ("#", .symbol),
        ("-", .symbol)
    ])
    func characterKinds(character: Character, kind: GeneratedCharacterKind) {
        #expect(GeneratedCharacterKind(character) == kind)
    }

    @Test func usernameHasTwoWordsAndANumber() {
        var generator = SplitMix64(state: 5)
        let parts = SecretGenerator.username(using: &generator).split(separator: ".")
        #expect(parts.count == 2)
        #expect(parts.last?.suffix(2).allSatisfy({ $0.isNumber }) == true)
    }
}
