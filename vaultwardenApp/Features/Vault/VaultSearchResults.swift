import SwiftUI

/// Search across the whole active vault from the iPhone home screen.
struct VaultSearchResults: View {
    let query: String
    @EnvironmentObject private var store: AppStore
    @StateObject private var actions = VaultItemActionModel()

    var body: some View {
        let results = VaultSearchKeyCache.filter(store.activeItems, query: VaultSearchQuery(query))
            .sorted(by: store.settings.vaultSortOrder.areInIncreasingOrder)

        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results) { item in
                NavigationLink(value: item.id) {
                    VaultItemRow(item: item)
                }
                .modifier(VaultRowDrag(url: VaultItemPresentation.dragURL(for: item)))
                .contextMenu { VaultItemMenu(item: item, actions: actions) }
            }
            .listStyle(.plain)
            .vaultItemActions(actions)
        }
    }
}
