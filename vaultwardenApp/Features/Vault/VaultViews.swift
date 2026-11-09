import SwiftUI

/// One section of the vault as a list: All, a category, a folder or a collection.
struct VaultCollectionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.vaultIconContext) private var iconContext
    @Environment(\.displayScale) private var displayScale
    let filter: VaultFilter
    /// `true` only when hosted as a split view column, where the list selection
    /// is what drives the detail column. In a navigation stack the push comes
    /// from `NavigationLink`, so selection stays local and app state is left
    /// untouched.
    let usesColumnSelection: Bool
    private let externalSearchText: Binding<String>?
    private let onSelectionChange: ((Set<UUID>, Bool) -> Void)?
    @StateObject private var actions = VaultItemActionModel()
    @State private var compactSearchText = ""
    @State private var selection = Set<UUID>()
    @State private var showingAddItem = false
    @State private var editMode: VaultEditMode = .inactive

    init(
        filter: VaultFilter,
        usesColumnSelection: Bool,
        searchText: Binding<String>? = nil,
        onSelectionChange: ((Set<UUID>, Bool) -> Void)? = nil
    ) {
        self.filter = filter
        self.usesColumnSelection = usesColumnSelection
        externalSearchText = searchText
        self.onSelectionChange = onSelectionChange
    }

    private var searchText: String {
        externalSearchText?.wrappedValue ?? compactSearchText
    }

    private var searchTextBinding: Binding<String> {
        externalSearchText ?? $compactSearchText
    }

    private var category: VaultCategory? { filter.category }

    private var title: String { filter.builtInTitle ?? store.title(for: filter) }

    var body: some View {
        // Resolved once per render and handed down, so nothing below filters or sorts again.
        let liveItems = store.items(for: filter)
        let query = VaultSearchQuery(searchText)
        let displayedItems = VaultSearchKeyCache.filter(liveItems, query: query)
            .sorted(by: store.settings.vaultSortOrder.areInIncreasingOrder)

        content(liveItems: liveItems, displayedItems: displayedItems)
            .vaultEditMode($editMode)
            .vaultItemActions(actions)
            .onAppear {
                guard !editMode.isEditing else { return }
                selection.removeAll()
                onSelectionChange?([], false)
            }
            .task {
                VaultItemThumbnail.prefetch(
                    displayedItems.prefix(18),
                    context: iconContext,
                    points: VaultRowMetrics.iconSize,
                    scale: displayScale
                )
            }
            .onChange(of: editMode) { _, newValue in
                if !newValue.isEditing { selection.removeAll() }
                onSelectionChange?(newValue.isEditing ? selection : [], newValue.isEditing)
            }
            .onChange(of: selection) { _, newValue in
                onSelectionChange?(newValue, editMode.isEditing)
            }
            .onDisappear { onSelectionChange?([], false) }
            .navigationTitle(title)
            .navigationSubtitle(subtitle(count: liveItems.count))
            .vaultNavigationTitleDisplayMode(usesColumnSelection ? .large : .inline)
            .navigationBarBackButtonHidden(editMode.isEditing)
            .modifier(
                AdaptiveCollectionSearch(
                    text: searchTextBinding,
                    prompt: L10n.string("Search"),
                    isEnabled: !usesColumnSelection,
                    isEditing: editMode.isEditing
                )
            )
            .toolbar { toolbarContent(liveItems: liveItems, displayedItems: displayedItems) }
            .sheet(isPresented: $showingAddItem) {
                AddEditVaultItemView(
                    prefilledType: filter.newItemType,
                    prefilledFolder: filter.newItemFolder
                )
                .environmentObject(store)
            }
    }

    private func subtitle(count: Int) -> String {
        if editMode.isEditing {
            return L10n.format("%lld selected", selection.count)
        }
        return L10n.format("%lld items", count)
    }

    // MARK: Content

    @ViewBuilder
    private func content(liveItems: [VaultItem], displayedItems: [VaultItem]) -> some View {
        if displayedItems.isEmpty {
            emptyState(isSearching: !liveItems.isEmpty || !searchText.isEmpty)
        } else {
            list(displayedItems)
        }
    }

    @ViewBuilder
    private func emptyState(isSearching: Bool) -> some View {
        if isSearching, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label(filter.emptyTitle, systemImage: filter.emptySymbol)
            } actions: {
                if filter.offersNewItem {
                    Button("New Item") { showingAddItem = true }
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ displayedItems: [VaultItem]) -> some View {
        #if os(macOS)
        Group {
            if editMode.isEditing {
                List(selection: $selection) { sections(displayedItems) }
            } else {
                List(selection: $store.selectedItemID) { sections(displayedItems) }
                    .onDeleteCommand(perform: deleteSelectedItem)
                    .onCopyCommand(perform: copySelectedPassword)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            selectionMenu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { store.selectedItemID = id }
        }
        #else
        if editMode.isEditing, !usesColumnSelection {
            List(selection: $selection) { sections(displayedItems) }
                .listStyle(.plain)
                .refreshable { await store.syncFromPullToRefresh() }
        } else {
            List { sections(displayedItems) }
                .listStyle(.plain)
                .refreshable { await store.syncFromPullToRefresh() }
        }
        #endif
    }

    @ViewBuilder
    private func sections(_ displayedItems: [VaultItem]) -> some View {
        if category == .security {
            ForEach(VaultSecurityGroup.grouped(displayedItems)) { group in
                Section {
                    rows(group.items)
                } header: {
                    Text(group.issue.title)
                }
            }
        } else {
            Section {
                rows(displayedItems)
            }
            // No hairline above the first row.
            .listSectionSeparator(.hidden, edges: .top)
        }
    }

    private func rows(_ items: [VaultItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let isSelected = isRowSelected(item)
            let nextIsSelected = index + 1 < items.count && isRowSelected(items[index + 1])

            row(for: item, isSelected: isSelected)
                .tag(item.id)
                .listRowBackground(selectionBackground(at: index, items: items))
                .listRowSeparator(isSelected || nextIsSelected ? .hidden : .visible)
                .modifier(VaultRowDrag(url: VaultItemPresentation.dragURL(for: item)))
                #if os(iOS)
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    leadingSwipeActions(for: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    trailingSwipeActions(for: item)
                }
                .contextMenu {
                    if !editMode.isEditing {
                        VaultItemMenu(item: item, actions: actions)
                    }
                }
                #endif
        }
    }

    @ViewBuilder
    private func row(for item: VaultItem, isSelected: Bool) -> some View {
        let canCopyCode = store.canCopyVaultSecrets(item)
        #if os(macOS)
        // A native selectable List supports arrow keys and Command/Shift
        // multi-selection. Buttons around entire rows consume those gestures.
        if category == .codes, !editMode.isEditing, let secret = item.totpSecret {
            TOTPItemRow(item: item, secret: secret, canCopy: canCopyCode)
        } else {
            VaultItemRow(item: item)
        }
        #else
        if editMode.isEditing, usesColumnSelection {
            Button {
                withAnimation(VaultMotion.snappy) { toggleSelection(of: item.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(item.id) ? Color.white : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)

                    VaultItemRow(item: item, isSelected: selection.contains(item.id))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
        } else if editMode.isEditing {
            VaultItemRow(item: item)
        } else if category == .codes, let secret = item.totpSecret {
            TOTPItemRow(
                item: item,
                secret: secret,
                isSelected: isSelected,
                canCopy: canCopyCode,
                onSelect: usesColumnSelection ? { store.selectedItemID = item.id } : nil
            )
        } else if usesColumnSelection {
            Button {
                store.selectedItemID = item.id
            } label: {
                VaultItemRow(item: item, isSelected: isSelected)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item.id) {
                VaultItemRow(item: item)
            }
        }
        #endif
    }

    private func toggleSelection(of id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func isRowSelected(_ item: VaultItem) -> Bool {
        guard usesColumnSelection else { return false }
        #if os(macOS)
        // The Mac list draws its own selection.
        return false
        #else
        return editMode.isEditing ? selection.contains(item.id) : store.selectedItemID == item.id
        #endif
    }

    /// iPad draws the column selection as one rounded accent run across
    /// neighbouring selected rows.
    private func selectionBackground(at index: Int, items: [VaultItem]) -> some View {
        let isSelected = isRowSelected(items[index])
        let previousIsSelected = index > 0 && isRowSelected(items[index - 1])
        let nextIsSelected = index + 1 < items.count && isRowSelected(items[index + 1])
        return UnevenRoundedRectangle(
            topLeadingRadius: previousIsSelected ? 0 : 22,
            bottomLeadingRadius: nextIsSelected ? 0 : 22,
            bottomTrailingRadius: nextIsSelected ? 0 : 22,
            topTrailingRadius: previousIsSelected ? 0 : 22,
            style: .continuous
        )
        .fill(isSelected ? Color.accentColor : Color.clear)
        .padding(.horizontal, 12)
    }

    // MARK: Swipe actions (iPhone and iPad)

    @ViewBuilder
    private func leadingSwipeActions(for item: VaultItem) -> some View {
        let permissions = VaultItemPermissions(item: item, store: store)
        if !item.isDeleted, !editMode.isEditing {
            if permissions.canCopyPassword {
                Button {
                    actions.copy(.password, from: item, store: store)
                } label: {
                    Label("Copy Password", systemImage: "key.fill")
                }
                .tint(.blue)
            }
            if permissions.canEdit {
                Button {
                    actions.toggleFavorite(item, store: store)
                } label: {
                    Label(
                        item.isFavorite ? L10n.string("Remove from Favorites") : L10n.string("Add to Favorites"),
                        systemImage: item.isFavorite ? "star.slash.fill" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
        }
    }

    @ViewBuilder
    private func trailingSwipeActions(for item: VaultItem) -> some View {
        let permissions = VaultItemPermissions(item: item, store: store)
        if permissions.canEdit, !editMode.isEditing {
            if item.isDeleted {
                Button(role: .destructive) {
                    actions.requestPermanentDeletion([item])
                } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
                Button {
                    actions.restore([item], store: store)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
            } else {
                Button(role: .destructive) {
                    actions.trash([item], store: store)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    actions.archive([item], store: store)
                } label: {
                    Label(
                        item.isArchived ? L10n.string("Unarchive") : L10n.string("Archive"),
                        systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                .tint(.orange)
            }
        }
    }

    // MARK: Mac selection commands

    #if os(macOS)
    @ViewBuilder
    private func selectionMenu(for ids: Set<UUID>) -> some View {
        let selected = store.items.filter { ids.contains($0.id) }
        if selected.count == 1, let item = selected.first {
            VaultItemMenu(item: item, actions: actions)
        } else if !selected.isEmpty {
            let editable = selected.filter { VaultItemPermissions(item: $0, store: store).canEdit }
            if editable.allSatisfy(\.isDeleted), !editable.isEmpty {
                Button(L10n.format("Restore %lld Items", editable.count), systemImage: "arrow.uturn.backward") {
                    actions.restore(editable, store: store)
                }
                Button(L10n.format("Delete %lld Items Permanently", editable.count), systemImage: "trash", role: .destructive) {
                    actions.requestPermanentDeletion(editable)
                }
            } else if !editable.isEmpty {
                let active = editable.filter { !$0.isDeleted }
                Button(L10n.format("Archive %lld Items", active.count), systemImage: "archivebox") {
                    actions.archive(active.filter { !$0.isArchived }, store: store)
                }
                Button(L10n.format("Delete %lld Items", active.count), systemImage: "trash", role: .destructive) {
                    actions.requestTrash(active)
                }
            }
        }
    }

    /// Delete on the keyboard moves the selected item to Deleted after asking,
    /// because a stray key press is easy to miss.
    private func deleteSelectedItem() {
        guard let id = store.selectedItemID,
              let item = store.items.first(where: { $0.id == id }),
              VaultItemPermissions(item: item, store: store).canEdit else { return }
        if item.isDeleted {
            actions.requestPermanentDeletion([item])
        } else {
            actions.requestTrash([item])
        }
    }

    /// ⌘C on a selected login copies its password, when the person may.
    private func copySelectedPassword() -> [NSItemProvider] {
        guard let id = store.selectedItemID,
              let item = store.items.first(where: { $0.id == id }),
              VaultItemPermissions(item: item, store: store).canCopyPassword else { return [] }
        // Written after the command returns, so the concealed, self-clearing copy is
        // the one that stays on the pasteboard.
        Task { @MainActor in actions.copy(.password, from: item, store: store) }
        return []
    }
    #endif

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(liveItems: [VaultItem], displayedItems: [VaultItem]) -> some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .vaultLeading) {
                Button(hasSelectedAll(displayedItems) ? "Deselect All" : "Select All") {
                    withAnimation(VaultMotion.snappy) { toggleSelectAll(in: displayedItems) }
                }
                .tint(nil)
            }
        }

        #if os(macOS)
        if editMode.isEditing {
            ToolbarItem(placement: .primaryAction) { selectionModeButton(isEmpty: liveItems.isEmpty) }
        } else {
            ToolbarItem(placement: .automatic) {
                ControlGroup {
                    sortMenu(isEmpty: liveItems.isEmpty).menuIndicator(.hidden)
                    addItemButton
                }
            }
        }
        #else
        ToolbarItem(placement: .vaultTrailing) {
            selectionModeButton(isEmpty: liveItems.isEmpty)
                .tint(nil)
        }

        if !editMode.isEditing {
            ToolbarItem(placement: .vaultBottomBar) {
                sortMenu(isEmpty: liveItems.isEmpty)
                    .tint(nil)
            }

            ToolbarSpacer(.flexible, placement: .vaultBottomBar)

            if !usesColumnSelection {
                // iOS 26 renders this as the native bottom search pill.
                DefaultToolbarItem(kind: .search, placement: .vaultBottomBar)

                ToolbarSpacer(.flexible, placement: .vaultBottomBar)
            }

            ToolbarItem(placement: .vaultBottomBar) {
                addItemButton
                    .tint(nil)
            }
        }
        #endif

        if editMode.isEditing {
            ToolbarItemGroup(placement: .vaultBottomBar) {
                Button {
                    bulkSecondaryAction()
                } label: {
                    Label(bulkSecondaryTitle, systemImage: bulkSecondaryIcon)
                }
                .disabled(selection.isEmpty)
                .tint(nil)

                Spacer()

                Button(role: .destructive) {
                    bulkDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .tint(nil)
            }
        }
    }

    private var addItemButton: some View {
        Button("New Item", systemImage: "plus") { showingAddItem = true }
            .labelStyle(.iconOnly)
            .help("New Item")
    }

    @ViewBuilder
    private func selectionModeButton(isEmpty: Bool) -> some View {
        if usesColumnSelection, editMode.isEditing {
            Button("Done", systemImage: "checkmark", action: toggleSelectionMode)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
        } else {
            Button(editMode.isEditing ? "Done" : "Select", action: toggleSelectionMode)
                .disabled(isEmpty)
        }
    }

    private func toggleSelectionMode() {
        withAnimation(VaultMotion.snappy) {
            if editMode.isEditing {
                editMode = .inactive
                selection.removeAll()
            } else {
                editMode = .active
            }
        }
    }

    private func sortMenu(isEmpty: Bool) -> some View {
        Menu {
            Picker("Sort By", selection: $store.settings.vaultSortOrder) {
                ForEach(VaultSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.icon)
                        .tag(order)
                }
            }
            #if os(macOS)
            Divider()
            Button("Select Items", action: toggleSelectionMode)
                .disabled(isEmpty)
            #endif
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .help("Sort By")
    }

    // MARK: Bulk actions

    private var selectedItems: [VaultItem] {
        store.items.filter { selection.contains($0.id) }
    }

    private var bulkSecondaryTitle: String {
        if category == .deleted { return L10n.string("Restore") }
        if category == .archived { return L10n.string("Unarchive") }
        return L10n.string("Archive")
    }

    private var bulkSecondaryIcon: String {
        if category == .deleted { return "arrow.uturn.backward" }
        if category == .archived { return "tray.and.arrow.up" }
        return "archivebox"
    }

    /// Restoring and archiving lose nothing, so they happen at once.
    private func bulkSecondaryAction() {
        let items = selectedItems.filter { VaultItemPermissions(item: $0, store: store).canEdit }
        guard !items.isEmpty else { return }
        let deleted = items.filter(\.isDeleted)
        let others = items.filter { !$0.isDeleted }
        if !deleted.isEmpty { actions.restore(deleted, store: store) }
        if !others.isEmpty {
            // Archive acts on what isn't archived yet; in Archived it unarchives.
            let targets = category == .archived ? others.filter(\.isArchived) : others.filter { !$0.isArchived }
            actions.archive(targets, store: store)
        }
        finishSelectionMode()
    }

    /// Several items at once deserve a question, even when they can be restored.
    private func bulkDelete() {
        let items = selectedItems.filter { VaultItemPermissions(item: $0, store: store).canEdit }
        guard !items.isEmpty else { return }
        if items.allSatisfy(\.isDeleted) {
            actions.requestPermanentDeletion(items)
        } else {
            actions.requestTrash(items.filter { !$0.isDeleted })
        }
        finishSelectionMode()
    }

    private func finishSelectionMode() {
        withAnimation(VaultMotion.snappy) {
            selection.removeAll()
            editMode = .inactive
        }
    }

    private func hasSelectedAll(_ displayedItems: [VaultItem]) -> Bool {
        let visible = Set(displayedItems.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private func toggleSelectAll(in displayedItems: [VaultItem]) {
        let visible = Set(displayedItems.map(\.id))
        if !visible.isEmpty, visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }
}

/// A row with a website drags out as that website, for a browser or a note.
struct VaultRowDrag: ViewModifier {
    let url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

/// Compact navigation uses the iOS 26 bottom search item. The regular-width
/// search is attached by `RootSplitView` to the detail column so it can occupy
/// the far-right toolbar position. Selection temporarily removes compact search
/// to keep it from competing with bulk actions.
private struct AdaptiveCollectionSearch: ViewModifier {
    @Binding var text: String
    let prompt: String
    let isEnabled: Bool
    let isEditing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, !isEditing {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}
