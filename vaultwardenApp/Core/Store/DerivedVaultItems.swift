import Foundation

/// Memoized views over one immutable `items` snapshot. `AppStore` drops the whole
/// cache whenever `items` changes, so nothing here can go stale.
final class DerivedVaultItems {
    let items: [VaultItem]

    init(items: [VaultItem]) {
        self.items = items
    }

    private(set) lazy var active: [VaultItem] = items.filter { !$0.isDeleted && !$0.isArchived }

    private(set) lazy var favorites: [VaultItem] = active.filter(\.isFavorite)

    private(set) lazy var unfoldered: [VaultItem] = active.filter { item in
        item.folder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private(set) lazy var organizations: [String] = Array(Set(active.compactMap(\.organization))).sorted()

    private var categories: [VaultCategory: [VaultItem]] = [:]
    private var folders: [String: [VaultItem]] = [:]
    private var organizationItems: [String: [VaultItem]] = [:]
    private var collections: [String: [VaultItem]] = [:]

    func items(in category: VaultCategory) -> [VaultItem] {
        if let cached = categories[category] { return cached }
        let result: [VaultItem] = switch category {
        case .logins: active.filter { $0.type == .login }
        case .passkeys: active.filter { $0.passkeyCount > 0 }
        case .codes: active.filter { $0.totpSecret?.isEmpty == false }
        case .cards: active.filter { $0.type == .card }
        case .identities: active.filter { $0.type == .identity }
        case .sshKeys: active.filter { $0.type == .sshKey }
        case .secureNotes: active.filter { $0.type == .secureNote }
        case .security: active.filter { !$0.risks.isEmpty }
        case .archived: items.filter { $0.isArchived && !$0.isDeleted }
        case .deleted: items.filter(\.isDeleted)
        }
        categories[category] = result
        return result
    }

    func items(inFolder folder: String) -> [VaultItem] {
        if let cached = folders[folder] { return cached }
        let result = active.filter { $0.folder == folder }
        folders[folder] = result
        return result
    }

    func items(inOrganization organization: String) -> [VaultItem] {
        if let cached = organizationItems[organization] { return cached }
        let result = active.filter { $0.organization == organization }
        organizationItems[organization] = result
        return result
    }

    func items(inCollection identifier: String) -> [VaultItem] {
        if let cached = collections[identifier] { return cached }
        let result = active.filter { $0.collectionIDs.contains(identifier) }
        collections[identifier] = result
        return result
    }
}
