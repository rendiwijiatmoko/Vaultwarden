import Foundation

/// What a person typed into search, folded once per keystroke.
nonisolated struct VaultSearchQuery: Equatable {
    let terms: [String]

    init(_ text: String) {
        terms = Self.fold(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Every term must appear in the key. Fields are separated by newlines, so a
    /// term never matches across two fields.
    func matches(_ key: String) -> Bool {
        terms.allSatisfy { key.contains($0) }
    }

    /// Case, accents and width don't matter, as in Passwords and Spotlight.
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

nonisolated enum VaultSearch {
    /// The text search looks at: names, user names, websites, folders and who a card
    /// or identity belongs to. Passwords, codes, notes, hidden fields and card
    /// numbers are never searched, so a match can't hint at a secret.
    static func key(for item: VaultItem) -> String {
        var fields = [item.name, item.username, item.type.localizedTitle]
        fields.append(contentsOf: item.websiteURIs)
        if let folder = item.folder { fields.append(folder) }
        if let organization = item.organization { fields.append(organization) }
        switch item.type {
        case .card:
            if let card = item.card { fields += [card.cardholderName, card.brand] }
        case .identity:
            if let identity = item.identity {
                fields += [identity.fullName, identity.username, identity.email, identity.company]
            }
        case .login, .secureNote, .sshKey:
            break
        }
        return VaultSearchQuery.fold(fields.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    static func filter(
        _ items: [VaultItem],
        query: VaultSearchQuery,
        key: (VaultItem) -> String = VaultSearch.key(for:)
    ) -> [VaultItem] {
        guard !query.isEmpty else { return items }
        return items.filter { query.matches(key($0)) }
    }
}

/// Folded search keys, kept between keystrokes and rebuilt only for items whose
/// searchable fields changed. Emptied when the vault locks.
enum VaultSearchKeyCache {
    private struct Entry {
        let stamp: Int
        let key: String
    }

    private static var entries: [UUID: Entry] = [:]

    static func key(for item: VaultItem) -> String {
        let stamp = Self.stamp(for: item)
        if let entry = entries[item.id], entry.stamp == stamp { return entry.key }
        let key = VaultSearch.key(for: item)
        entries[item.id] = Entry(stamp: stamp, key: key)
        return key
    }

    static func filter(_ items: [VaultItem], query: VaultSearchQuery) -> [VaultItem] {
        VaultSearch.filter(items, query: query, key: key(for:))
    }

    static func removeAll() {
        entries.removeAll()
    }

    /// Hashing the fields is much cheaper than folding them again.
    private static func stamp(for item: VaultItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.name)
        hasher.combine(item.username)
        hasher.combine(item.uri)
        hasher.combine(item.additionalURIs)
        hasher.combine(item.type)
        hasher.combine(item.folder)
        hasher.combine(item.organization)
        hasher.combine(item.card?.cardholderName)
        hasher.combine(item.card?.brand)
        hasher.combine(item.identity?.fullName)
        hasher.combine(item.identity?.username)
        hasher.combine(item.identity?.email)
        hasher.combine(item.identity?.company)
        return hasher.finalize()
    }
}
