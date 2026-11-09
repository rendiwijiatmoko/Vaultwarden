import Foundation

/// What rows and detail pages show about an item, derived without touching secrets.
nonisolated enum VaultItemPresentation {
    /// A row's secondary line: who or what the item is for. Never a secret.
    static func subtitle(for item: VaultItem) -> String {
        let value = detail(for: item)
        return value.isEmpty ? item.type.localizedTitle : value
    }

    private static func detail(for item: VaultItem) -> String {
        switch item.type {
        case .login:
            if !item.username.isEmpty { return item.username }
            return item.websiteURIs.lazy.compactMap(WebsiteIconHost.displayHost(for:)).first ?? ""
        case .card:
            guard let card = item.card else { return "" }
            let digits = card.number.filter(\.isNumber)
            let lastFour = digits.count > 4 ? "•••• \(digits.suffix(4))" : ""
            return [card.brand, lastFour].filter { !$0.isEmpty }.joined(separator: " ")
        case .identity:
            guard let identity = item.identity else { return "" }
            return [identity.fullName, identity.email, identity.company].first { !$0.isEmpty } ?? ""
        case .sshKey:
            return item.displayedSSHFingerprint
        case .secureNote:
            return ""
        }
    }

    /// The first website that opens in a browser.
    static func websiteURL(for item: VaultItem) -> URL? {
        item.websiteURIs.lazy.compactMap { item.websiteURL(for: $0) }.first
    }

    /// The site's standard change-password address (`/.well-known/change-password`),
    /// which Passwords opens too. The site redirects it to the right page.
    static func changePasswordURL(for item: VaultItem) -> URL? {
        guard item.type == .login else { return nil }
        for uri in item.websiteURIs {
            guard let url = item.websiteURL(for: uri),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host?.isEmpty == false else { continue }
            components.scheme = "https"
            components.user = nil
            components.password = nil
            components.path = "/.well-known/change-password"
            components.query = nil
            components.fragment = nil
            if let changeURL = components.url { return changeURL }
        }
        return nil
    }

    /// What a row is dragged out as: its website, never a secret.
    static func dragURL(for item: VaultItem) -> URL? {
        item.type == .login ? websiteURL(for: item) : nil
    }
}

/// Normalizes what a person types into a website field.
nonisolated enum VaultWebsiteInput {
    enum Result: Equatable {
        case empty
        case valid(String)
        case invalid
    }

    /// Trims the entry and gives a bare domain an `https://` scheme, as the
    /// Bitwarden clients do. Anything with a scheme (including app identifiers
    /// such as `androidapp://`) is kept as typed. Spaces inside make it invalid.
    static func normalize(_ input: String) -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !trimmed.contains(where: \.isWhitespace) else { return .invalid }
        if trimmed.contains("://") { return .valid(trimmed) }
        guard trimmed.contains("."),
              let host = URLComponents(string: "https://\(trimmed)")?.host,
              !host.isEmpty else { return .valid(trimmed) }
        return .valid("https://\(trimmed)")
    }

    /// The domain an untitled login can be named after.
    static func suggestedName(for input: String) -> String? {
        guard case let .valid(value) = normalize(input) else { return nil }
        return WebsiteIconHost.displayHost(for: value)
    }
}

/// How a code reads and when it changes.
nonisolated enum TOTPDisplay {
    /// "123 456", or "1234 5678" for eight digits: two groups, as Passwords shows them.
    static func grouped(_ code: String) -> String {
        guard code.count > 4 else { return code }
        let splitIndex = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<splitIndex]) \(code[splitIndex...])"
    }

    /// Whole seconds until the code changes, from `period` down to 1.
    static func secondsRemaining(at date: Date, period: Int) -> Int {
        let period = max(period, 1)
        let elapsed = Int(date.timeIntervalSince1970.rounded(.down)) % period
        return period - elapsed
    }
}
