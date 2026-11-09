import Foundation
import SwiftUI

/// A single, value-typed description of "which slice of the vault is on screen".
///
/// Every navigable section of the vault (categories, favorites, folders,
/// organization collections and live search) resolves to one of these cases.
/// Because it is `Hashable` it can drive `NavigationSplitView` column selection
/// directly, which is what makes the same view tree collapse into a stack on
/// iPhone and expand into a sidebar layout on iPad and the Mac.
enum VaultFilter: Hashable, Identifiable {
    case all
    case category(VaultCategory)
    case favorites
    case unfoldered
    case folder(String)
    case collection(String)
    case organization(String)

    /// Kept for callers that open the login list directly.
    static let login = VaultFilter.category(.logins)

    /// The section a regular-width window opens on, as Passwords opens on All.
    static let defaultSelection = VaultFilter.all

    /// The smart sections at the top of the home screen and sidebar, in Passwords' order.
    static let smartSections: [VaultFilter] = [
        .all, .favorites, .category(.passkeys), .category(.codes), .category(.security), .category(.deleted)
    ]

    /// Item types, listed under the smart sections.
    static let typeSections: [VaultFilter] = [
        .category(.logins), .category(.cards), .category(.identities), .category(.secureNotes), .category(.sshKeys)
    ]

    var id: String {
        switch self {
        case let .category(category): "category:\(category.rawValue)"
        case .all: "all"
        case .favorites: "favorites"
        case .unfoldered: "unfoldered"
        case let .folder(name): "folder:\(name)"
        case let .collection(identifier): "collection:\(identifier)"
        case let .organization(name): "organization:\(name)"
        }
    }

    /// Non-nil only for the built-in categories, so category-specific behaviour
    /// (code rows, the security recommendations) keeps working unchanged.
    var category: VaultCategory? {
        if case let .category(category) = self { return category }
        return nil
    }

    /// Titles for the built-in sections, in the words Passwords uses. Folders and
    /// collections are named by the person, so they have none here.
    var builtInTitle: String? {
        switch self {
        case .all: L10n.string("All")
        case .favorites: L10n.string("Favorites")
        case .unfoldered: L10n.string("No Folder")
        case let .category(category):
            switch category {
            case .logins: L10n.string("Passwords")
            case .passkeys: L10n.string("Passkeys")
            case .codes: L10n.string("Codes")
            case .cards: L10n.string("Cards")
            case .identities: L10n.string("Identities")
            case .sshKeys: L10n.string("SSH Keys")
            case .secureNotes: L10n.string("Notes")
            case .security: L10n.string("Security")
            case .archived: L10n.string("Archived")
            case .deleted: L10n.string("Deleted")
            }
        case .folder, .collection, .organization: nil
        }
    }

    /// The empty state's title. One line, no explanation.
    var emptyTitle: String {
        switch self {
        case .all, .folder, .collection, .organization, .unfoldered: L10n.string("No Items")
        case .favorites: L10n.string("No Favorites")
        case let .category(category):
            switch category {
            case .logins: L10n.string("No Passwords")
            case .passkeys: L10n.string("No Passkeys")
            case .codes: L10n.string("No Codes")
            case .cards: L10n.string("No Cards")
            case .identities: L10n.string("No Identities")
            case .sshKeys: L10n.string("No SSH Keys")
            case .secureNotes: L10n.string("No Notes")
            case .security: L10n.string("No Issues Found")
            case .archived: L10n.string("No Archived Items")
            case .deleted: L10n.string("No Deleted Items")
            }
        }
    }

    /// The symbol for an empty list. Security reads as a clean bill of health.
    var emptySymbol: String {
        category == .security ? "checkmark.shield.fill" : icon
    }

    /// Whether an empty list offers New Item. Sections that only collect items
    /// made elsewhere (codes, passkeys, security, archive, trash) don't.
    var offersNewItem: Bool {
        switch self {
        case .all, .unfoldered, .folder: true
        case .favorites, .collection, .organization: false
        case let .category(category):
            switch category {
            case .logins, .cards, .identities, .secureNotes, .sshKeys: true
            case .passkeys, .codes, .security, .archived, .deleted: false
            }
        }
    }

    /// Seeds the new-item editor from the section the user is currently
    /// browsing. The editor still presents its normal picker, so this is only
    /// an initial selection and never locks the item type.
    var newItemType: VaultItemType {
        switch self {
        case .category(.cards): .card
        case .category(.identities): .identity
        case .category(.secureNotes): .secureNote
        case .category(.sshKeys): .sshKey
        default: .login
        }
    }

    /// A folder list should create items in that folder by default. As with
    /// the type seed, users can change or clear this in the editor.
    var newItemFolder: String {
        if case let .folder(name) = self { return name }
        return ""
    }

    var icon: String {
        switch self {
        case .category(.logins): "key.horizontal.fill"
        case let .category(category): category.icon
        case .all: "key.fill"
        case .favorites: "star.fill"
        case .unfoldered: "tray.fill"
        case .folder: "folder.fill"
        case .collection, .organization: "person.2.fill"
        }
    }

    var color: Color {
        switch self {
        case let .category(category):
            switch category {
            case .logins: .blue
            case .passkeys: .green
            case .codes: .orange
            case .cards: .cyan
            case .identities: .teal
            case .sshKeys: .indigo
            case .secureNotes: .brown
            case .security: .red
            case .archived: .gray
            case .deleted: .gray
            }
        case .all: .blue
        case .favorites: .yellow
        case .unfoldered: .gray
        case .folder: .blue
        case .collection, .organization: .green
        }
    }

    /// Sections that only make sense once the user goes looking for them.
    static let hiddenCategories: [VaultCategory] = [.archived, .deleted]

    /// Built-in cards on the adaptive dashboard grid: everything except the
    /// hidden ones, with `Login` kept as the leading card.
    static let dashboardCategories: [VaultCategory] = VaultCategory.allCases.filter {
        !hiddenCategories.contains($0)
    }
}

struct VaultCollectionGroup: Identifiable {
    var id: String
    var name: String
    var filters: [VaultFilter]

    static func grouped(collections: [VaultCollection], organizations: [String]) -> [Self] {
        let grouped = Dictionary(grouping: collections) {
            $0.organizationID.map { "id:\($0)" } ?? "name:\($0.organization)"
        }
        var groups = grouped.map { id, collections in
            Self(id: id, name: collections[0].organization, filters: collections.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }.map { .collection($0.id) })
        }
        // Preserve navigation for organizations that have no visible collections.
        let representedNames = Set(collections.map(\.organization))
        groups += organizations.filter { !representedNames.contains($0) }.map {
            Self(id: "name:\($0)", name: $0, filters: [.organization($0)])
        }
        return groups.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
