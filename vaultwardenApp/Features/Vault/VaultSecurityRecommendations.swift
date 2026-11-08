import Foundation

/// The one issue a login's security row talks about, most urgent first.
nonisolated enum VaultSecurityIssue: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case compromised
    case reused
    case weak
    case unsecuredWebsite

    var id: Int { rawValue }

    init?(risks: Set<VaultRisk>) {
        guard let issue = Self.allCases.first(where: { risks.contains($0.risk) }) else { return nil }
        self = issue
    }

    var risk: VaultRisk {
        switch self {
        case .compromised: .exposed
        case .reused: .reused
        case .weak: .weak
        case .unsecuredWebsite: .unsecured
        }
    }

    /// Section headers on the Security list.
    var title: String {
        switch self {
        case .compromised: L10n.string("Compromised")
        case .reused: L10n.string("Reused")
        case .weak: L10n.string("Weak")
        case .unsecuredWebsite: L10n.string("Not Secure")
        }
    }

    /// The single quiet line on an item's page.
    var message: String {
        switch self {
        case .compromised: L10n.string("This password appeared in a data leak.")
        case .reused: L10n.string("This password is reused.")
        case .weak: L10n.string("This password is easy to guess.")
        case .unsecuredWebsite: L10n.string("This website doesn't use HTTPS.")
        }
    }

    var symbol: String {
        switch self {
        case .compromised: "exclamationmark.triangle.fill"
        case .reused, .weak: "exclamationmark.circle.fill"
        case .unsecuredWebsite: "lock.open.fill"
        }
    }

    /// Compromised passwords are urgent; the rest are recommendations.
    var isUrgent: Bool { self == .compromised }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct VaultSecurityGroup: Identifiable, Sendable {
    let issue: VaultSecurityIssue
    let items: [VaultItem]

    var id: Int { issue.rawValue }

    /// Each item appears once, under its most urgent issue, so a list keeps
    /// one row (and one selection) per item. Order inside a group is kept.
    static func grouped(_ items: [VaultItem]) -> [VaultSecurityGroup] {
        var buckets: [VaultSecurityIssue: [VaultItem]] = [:]
        for item in items {
            guard let issue = VaultSecurityIssue(risks: item.risks) else { continue }
            buckets[issue, default: []].append(item)
        }
        return VaultSecurityIssue.allCases.compactMap { issue in
            guard let members = buckets[issue], !members.isEmpty else { return nil }
            return VaultSecurityGroup(issue: issue, items: members)
        }
    }
}

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
