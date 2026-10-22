import Foundation
import SwiftUI

nonisolated enum VaultItemType: String, CaseIterable, Codable, Identifiable, Sendable {
    case login = "Login"
    case secureNote = "Secure Note"
    case card = "Card"
    case identity = "Identity"
    case sshKey = "SSH Key"

    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }

    var icon: String {
        switch self {
        case .login: "key.fill"
        case .secureNote: "note.text"
        case .card: "creditcard.fill"
        case .identity: "person.text.rectangle.fill"
        case .sshKey: "terminal.fill"
        }
    }
}

nonisolated enum VaultRisk: String, Codable, CaseIterable, Sendable {
    case weak = "Weak password"
    case reused = "Reused password"
    case exposed = "Exposed password"
    case unsecured = "Unsecured website"

    var localizedTitle: String { L10n.string(rawValue) }
}

nonisolated enum VaultCustomFieldType: String, CaseIterable, Codable, Identifiable, Sendable {
    case text = "Text"
    case hidden = "Hidden"
    case boolean = "Boolean"
    case linked = "Linked"

    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .hidden: "eye.slash.fill"
        case .boolean: "checkmark.square.fill"
        case .linked: "link"
        }
    }
}

nonisolated struct VaultCustomField: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String = ""
    var value: String = ""
    var type: VaultCustomFieldType = .text
}

nonisolated struct CardDetails: Hashable, Codable, Sendable {
    var cardholderName = ""
    var brand = ""
    var number = ""
    var expirationMonth = ""
    var expirationYear = ""
    var securityCode = ""
    var validFromMonth = ""
    var validFromYear = ""

    var expirationDisplay: String {
        guard !expirationMonth.isEmpty || !expirationYear.isEmpty else { return L10n.string("Not set") }
        return [expirationMonth, expirationYear].filter { !$0.isEmpty }.joined(separator: "/")
    }

    var maskedNumber: String {
        let digits = number.filter(\.isNumber)
        guard digits.count > 4 else { return number }
        return "•••• •••• •••• \(digits.suffix(4))"
    }
}

nonisolated struct IdentityDetails: Hashable, Codable, Sendable {
    var title = ""
    var firstName = ""
    var middleName = ""
    var lastName = ""
    var username = ""
    var company = ""
    var email = ""
    var phone = ""
    var socialSecurityNumber = ""
    var passportNumber = ""
    var licenseNumber = ""
    var address1 = ""
    var address2 = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""

    var fullName: String {
        [title, firstName, middleName, lastName]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }
}

nonisolated struct VaultPasswordHistoryEntry: Hashable, Codable, Sendable {
    var password: String
    var lastUsedDate: Date
}

nonisolated struct VaultItem: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var username: String = ""
    var password: String = ""
    /// Optional to preserve compatibility with older encrypted caches and exports.
    var passwordHistory: [VaultPasswordHistoryEntry]?
    /// Server login.passwordRevisionDate; optional for older caches.
    var passwordUpdatedAt: Date?
    var uri: String = ""
    /// Additional login websites after the primary `uri`. Optional keeps
    /// cached items written by older app versions decodable.
    var additionalURIs: [String]?
    var type: VaultItemType = .login
    var folder: String?
    var organization: String?
    var collectionIDs: [String] = []
    var notes: String = ""
    /// Optional for compatibility with older encrypted caches and exports.
    var sshKeyFingerprint: String? = nil
    var isFavorite = false
    var totpSecret: String?
    var passkeyCount = 0
    var attachments: [VaultAttachment]? = nil
    var risks: Set<VaultRisk> = []
    var card: CardDetails?
    var identity: IdentityDetails?
    var customFields: [VaultCustomField] = []
    var createdAt: Date? = nil
    var deletedAt: Date? = nil
    var archivedAt: Date? = nil
    var updatedAt = Date()

    /// Base history on the latest local item so consecutive offline edits retain
    /// every change even while the remote cipher still represents an older sync.
    mutating func recordPasswordChange(from previous: VaultItem, at date: Date) {
        passwordHistory = previous.passwordHistory
        passwordUpdatedAt = previous.passwordUpdatedAt
        if type == .login, previous.type != .login || previous.password != password {
            passwordUpdatedAt = date
        }
        guard previous.type == .login, type == .login,
              !previous.password.isEmpty, previous.password != password else { return }
        var history = previous.passwordHistory ?? []
        history.insert(VaultPasswordHistoryEntry(password: previous.password, lastUsedDate: date), at: 0)
        passwordHistory = Array(history.prefix(5))
    }

    var displayedSSHFingerprint: String {
        sshKeyFingerprint ?? (type == .sshKey && notes.hasPrefix("SHA256:") ? notes : "")
    }

    var isDeleted: Bool { deletedAt != nil }
    var isArchived: Bool { archivedAt != nil }

    var websiteURIs: [String] {
        ([uri] + (additionalURIs ?? []))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// An absolute HTTP(S) URL suitable for opening in a browser. Vault URIs
    /// commonly omit the scheme, so treat a bare host as HTTPS by default.
    var websiteURL: URL? {
        websiteURL(for: uri)
    }

    func websiteURL(for uri: String) -> URL? {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let hasExplicitScheme = value.range(
            of: "^[A-Za-z][A-Za-z0-9+.-]*://",
            options: .regularExpression
        ) != nil
        let candidate = hasExplicitScheme ? value : "https://\(value)"

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return nil
        }
        return components.url
    }

    var displaySubtitle: String {
        if type == .card, let card, !card.cardholderName.isEmpty {
            return [card.brand, card.maskedNumber].filter { !$0.isEmpty }.joined(separator: " • ")
        }
        if type == .identity, let identity, !identity.fullName.isEmpty { return identity.fullName }
        if !username.isEmpty { return username }
        if !uri.isEmpty { return uri }
        return type.localizedTitle
    }
}

nonisolated struct VaultAttachment: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var fileName: String
    var size: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

nonisolated struct VaultCollection: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var organization: String
    var isReadOnly: Bool
    var hidesPasswords: Bool
    /// Server identity keeps organizations with identical names separate.
    var organizationID: String? = nil
}

enum VaultCategory: String, CaseIterable, Identifiable {
    case logins = "Login"
    case passkeys = "Passkeys"
    case codes = "Codes"
    case cards = "Cards"
    case identities = "Identity"
    case sshKeys = "SSH Keys"
    case secureNotes = "Secure Notes"
    case security = "Security"
    case archived = "Archived"
    case deleted = "Deleted"

    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }

    var icon: String {
        switch self {
        case .logins: "key.fill"
        case .passkeys: "person.badge.key.fill"
        case .codes: "lock.rotation"
        case .cards: "creditcard.fill"
        case .identities: "person.text.rectangle.fill"
        case .sshKeys: "terminal.fill"
        case .secureNotes: "note.text"
        case .security: "exclamationmark.shield.fill"
        case .archived: "archivebox.fill"
        case .deleted: "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .logins: .vaultBlue
        case .passkeys: .vaultGreen
        case .codes: .vaultYellow
        case .cards: .vaultCyan
        case .identities: .vaultGreen
        case .sshKeys: .vaultRed
        case .secureNotes: .vaultOrange
        case .security: .vaultRed
        case .archived: .secondary
        case .deleted: .vaultOrange
        }
    }
}

nonisolated struct VaultFolder: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var icon = "folder.fill"
}

nonisolated enum SendKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case text = "Text"
    case file = "File"
    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }
    var icon: String { self == .text ? "text.alignleft" : "doc.fill" }
}

nonisolated enum SendPasswordUpdate: Codable, Sendable, Equatable {
    case preserve
    case set(String)
    case remove
}

nonisolated struct SendItem: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var kind: SendKind
    var text: String = ""
    var fileName: String?
    var fileID: String?
    var fileSize: String?
    var accessCount = 0
    var maximumAccessCount: Int?
    var expiresAt: Date?
    var deletesAt: Date
    var passwordProtected = false
    var isDisabled = false
    /// Nil until Vaultwarden has assigned an access ID and the SDK-derived Send key.
    var shareURL: URL?

    var isExpired: Bool { (expiresAt.map { $0 <= Date() } ?? false) || deletesAt <= Date() || isDisabled }
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }
}

enum VaultTimeout: String, CaseIterable, Identifiable, Codable {
    case immediately = "Immediately"
    case oneMinute = "1 minute"
    case fiveMinutes = "5 minutes"
    case tenMinutes = "10 minutes"
    case fifteenMinutes = "15 minutes"
    case never = "Never"
    var id: String { rawValue }
    var localizedTitle: String { L10n.string(rawValue) }

    var timeInterval: TimeInterval? {
        switch self {
        case .immediately: 0
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .fifteenMinutes: 15 * 60
        case .never: nil
        }
    }
}

/// Persistent SSH approval is scoped to an account, vault item, and public key.
/// This contains no private key material and grants no access while locked.
struct SSHAgentApproval: Codable, Equatable {
    let accountID: String
    let serverURL: URL
    let keyID: UUID
    let fingerprint: String
}

enum VaultSortOrder: String, CaseIterable, Identifiable, Codable {
    case nameAscending
    case nameDescending
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
        return L10n.string(key)
    }

    var icon: String {
        switch self {
        case .nameAscending: "textformat.abc"
        case .nameDescending: "textformat.abc"
        case .newestFirst: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .oldestFirst: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
        }
    }

    nonisolated func areInIncreasingOrder(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
        let comparison: ComparisonResult
        switch self {
        case .nameAscending, .nameDescending:
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        case .newestFirst, .oldestFirst:
            comparison = lhs.updatedAt.compare(rhs.updatedAt)
        }
        if comparison == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return comparison == (self == .nameDescending || self == .newestFirst
            ? .orderedDescending : .orderedAscending)
    }

    func sortedFolders(_ folders: [VaultFolder]) -> [VaultFolder] {
        // The server supplies no folder timestamps; date modes retain its order.
        guard self == .nameAscending || self == .nameDescending else { return folders }
        return folders.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison == .orderedSame { return lhs.id.uuidString < rhs.id.uuidString }
            return comparison == (self == .nameAscending ? .orderedAscending : .orderedDescending)
        }
    }
}

struct AppSettings: Codable {
    var serverURL = ""
    var email = ""
    var sessionReference: String?
    var biometricUnlock = true
    var requireBiometricForSensitiveActions = true
    var devicePasscodeFallback = false
    var clearClipboard = true
    var showFavicons = true
    var haptics = true
    var autoSync = true
    var syncOnOpen = true
    var backgroundRefresh = true
    /// Nil preserves compatibility with settings saved before URI detection was configurable.
    var defaultURIMatchDetection: AutoFillURIMatchType?
    /// Optional so existing settings retain their values when upgrading.
    var sshAgentEnabled: Bool?
    var sshAgentAllowedKeyIDs: [UUID]?
    var sshAgentApprovals: [SSHAgentApproval]?
    /// Optional storage allows settings from older versions to decode unchanged.
    var savedVaultSortOrder: VaultSortOrder?
    var vaultSortOrder: VaultSortOrder {
        get { savedVaultSortOrder ?? .newestFirst }
        set { savedVaultSortOrder = newValue }
    }
    var theme: AppTheme = .system
    #if os(macOS)
    var vaultTimeout: VaultTimeout = .fiveMinutes
    #else
    var vaultTimeout: VaultTimeout = .immediately
    #endif
}
