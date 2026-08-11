import Foundation
import SwiftUI

/// A single, value-typed description of "which slice of the vault is on screen".
///
/// Every navigable section of the vault — categories, favorites, folders,
/// organization collections and live search — resolves to one of these cases.
/// Because it is `Hashable` it can drive `NavigationSplitView` column selection
/// directly, which is what makes the same view tree collapse into a stack on
/// iPhone and expand into a sidebar layout on iPad.
enum VaultFilter: Hashable, Identifiable {
    case category(VaultCategory)
    case favorites
    case unfoldered
    case folder(String)
    case collection(String)
    case organization(String)

    /// The section selected by default when the split view has room for a list.
    static let login = VaultFilter.category(.logins)

    var id: String {
        switch self {
        case let .category(category): "category:\(category.rawValue)"
        case .favorites: "favorites"
        case .unfoldered: "unfoldered"
        case let .folder(name): "folder:\(name)"
        case let .collection(identifier): "collection:\(identifier)"
        case let .organization(name): "organization:\(name)"
        }
    }

    /// Non-nil only for the built-in categories, so existing category-specific
    /// behaviour (TOTP rows, the security dashboard) keeps working unchanged.
    var category: VaultCategory? {
        if case let .category(category) = self { return category }
        return nil
    }

    var icon: String {
        switch self {
        case let .category(category): category.icon
        case .favorites: "star.fill"
        case .unfoldered: "questionmark.folder.fill"
        case .folder: "folder.fill"
        case .collection, .organization: "person.2.fill"
        }
    }

    var color: Color {
        switch self {
        case let .category(category): category.color
        case .favorites: .vaultYellow
        case .unfoldered: .secondary
        case .folder: .vaultBlue
        case .collection, .organization: .vaultGreen
        }
    }

    /// Sections that only make sense once the user goes looking for them.
    static let hiddenCategories: [VaultCategory] = [.archived, .deleted]

    /// Built-in cards on the adaptive dashboard grid — everything except the
    /// hidden ones, with `Login` kept as the leading card.
    static let dashboardCategories: [VaultCategory] = VaultCategory.allCases.filter {
        !hiddenCategories.contains($0)
    }
}
