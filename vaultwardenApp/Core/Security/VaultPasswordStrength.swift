import Foundation

/// A conservative guess at whether a password is easy to guess: short, made of
/// one kind of character, a common password, or one character repeated.
/// It runs on device only; the password never leaves memory.
nonisolated enum VaultPasswordStrength {
    private static let commonPasswords: Set<String> = [
        "password", "passw0rd", "123456", "12345678", "123456789", "1234567890", "qwerty", "qwertyuiop",
        "letmein", "iloveyou", "admin", "welcome", "monkey", "dragon", "football", "baseball", "abc123",
        "111111", "000000", "sunshine", "princess", "trustno1", "master", "login", "starwars", "secret"
    ]

    /// Bits a guesser has to cover, from length and the kinds of characters used.
    static func estimatedEntropy(of password: String) -> Double {
        var poolSize = 0
        if password.contains(where: \.isLowercase) { poolSize += 26 }
        if password.contains(where: \.isUppercase) { poolSize += 26 }
        if password.contains(where: \.isNumber) { poolSize += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { poolSize += 33 }
        guard poolSize > 0 else { return 0 }
        return Double(password.count) * log2(Double(poolSize))
    }

    static func isWeak(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        if password.count < 8 { return true }
        if Set(password).count <= 2 { return true }
        let core = password.lowercased().filter(\.isLetter)
        if commonPasswords.contains(password.lowercased()) || (core.count >= 4 && commonPasswords.contains(core)) {
            return true
        }
        return estimatedEntropy(of: password) < 50
    }
}
