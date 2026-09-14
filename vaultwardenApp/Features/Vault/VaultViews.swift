import SwiftUI
import UIKit
import VisionKit
internal import Vision

struct VaultSyncStatusText: View {
    @EnvironmentObject private var store: AppStore

    private var appearance: (text: String, color: Color) {
        if store.isSyncing {
            return (L10n.string("Syncing encrypted vault…"), .vaultBlue)
        }
        if store.pendingMutationCount > 0 {
            return (
                L10n.format("%lld encrypted changes queued", store.pendingMutationCount),
                .vaultOrange
            )
        }
        if store.lastSyncError != nil {
            return (L10n.string("Sync failed · Pull to retry"), .vaultRed)
        }
        if store.lastSyncUsedOfflineCache {
            return (L10n.string("Showing offline vault · Pull to retry"), .vaultYellow)
        }
        return (
            L10n.format("Synced %@", store.lastSync.formatted(.relative(presentation: .named))),
            .vaultGreen
        )
    }

    var body: some View {
        let appearance = appearance
        Text(appearance.text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(appearance.color)
            .animation(.snappy, value: store.isSyncing)
            .animation(.snappy, value: store.pendingMutationCount)
            .animation(.snappy, value: store.lastSyncError)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(appearance.text)
    }
}

private enum VaultRowAction: Equatable {
    case delete(UUID)
    case archive(UUID)

    var itemID: UUID {
        switch self {
        case let .delete(id), let .archive(id): id
        }
    }
}

private enum VaultSortOrder: String, CaseIterable, Identifiable {
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

    func areInIncreasingOrder(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
        switch self {
        case .nameAscending:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .nameDescending:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        case .newestFirst:
            return lhs.updatedAt > rhs.updatedAt
        case .oldestFirst:
            return lhs.updatedAt < rhs.updatedAt
        }
    }
}

struct VaultCollectionView: View {
    @EnvironmentObject private var store: AppStore
    let filter: VaultFilter
    /// `true` only when hosted as a split view column, where the list selection
    /// is what drives the detail column. In a navigation stack the push comes
    /// from `NavigationLink`, so selection stays local and app state is left
    /// untouched.
    let usesColumnSelection: Bool
    private let externalSearchText: Binding<String>?
    private let onSelectionChange: ((Set<UUID>, Bool) -> Void)?
    @State private var compactSearchText = ""
    @State private var selection = Set<UUID>()
    @State private var showingAddItem = false
    @State private var editMode: EditMode = .inactive
    @State private var pendingDeletion: [VaultItem] = []
    @State private var pendingArchive: [VaultItem] = []
    @State private var showingDeleteConfirmation = false
    @State private var showingArchiveConfirmation = false
    @State private var pendingRowAction: VaultRowAction?
    @State private var showingRowAlert = false
    @State private var sortOrder: VaultSortOrder = .newestFirst

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

    private var title: String { store.title(for: filter) }

    /// Always resolved against the live store, so newly added or edited items
    /// show up without re-entering the list.
    private var liveItems: [VaultItem] { store.items(for: filter) }

    private var filteredItems: [VaultItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? liveItems : liveItems.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || $0.websiteURIs.contains { $0.localizedCaseInsensitiveContains(query) }
                || $0.type.rawValue.localizedCaseInsensitiveContains(query)
        }
        return matches.sorted(by: sortOrder.areInIncreasingOrder)
    }

    private var selectedItems: [VaultItem] {
        store.items.filter { selection.contains($0.id) }
    }

    private var subtitle: String {
        if editMode.isEditing {
            return L10n.format("%lld selected", selection.count)
        }
        if category == .security {
            return L10n.format("%lld recommendations", liveItems.count)
        }
        return L10n.format("%lld items", liveItems.count)
    }

    var body: some View {
        let displayedItems = filteredItems

        Group {
            if displayedItems.isEmpty, category != .security {
                EmptyStateView(
                    icon: searchText.isEmpty ? (category?.icon ?? "folder") : "magnifyingglass",
                    title: L10n.string(searchText.isEmpty ? "Nothing here" : "No Results"),
                    message: searchText.isEmpty
                        ? L10n.string("Items in this section will appear here.")
                        : L10n.format("No vault items match “%@”.", searchText)
                )
            } else if editMode.isEditing {
                // Multi-select for bulk actions.
                if usesColumnSelection {
                    List { listSections(displayedItems) }
                        .listStyle(.plain)
                        .refreshable { await store.syncFromPullToRefresh() }
                } else {
                    List(selection: $selection) { listSections(displayedItems) }
                        .listStyle(.plain)
                        .refreshable { await store.syncFromPullToRefresh() }
                }
            } else {
                List { listSections(displayedItems) }
                    .listStyle(.plain)
                    .refreshable { await store.syncFromPullToRefresh() }
            }
        }
        .environment(\.editMode, $editMode)
        .onAppear {
            guard !editMode.isEditing else { return }
            selection.removeAll()
            onSelectionChange?([], false)
        }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selection.removeAll()
            }
            onSelectionChange?(newValue.isEditing ? selection : [], newValue.isEditing)
        }
        .onChange(of: selection) { _, newValue in
            onSelectionChange?(newValue, editMode.isEditing)
        }
        .onDisappear { onSelectionChange?([], false) }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(usesColumnSelection ? .large : .inline)
        .navigationBarBackButtonHidden(editMode.isEditing)
        .modifier(
            AdaptiveCollectionSearch(
                text: searchTextBinding,
                prompt: L10n.format("Search %@", title.lowercased()),
                isEnabled: !usesColumnSelection,
                isEditing: editMode.isEditing
            )
        )
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(hasSelectedAllVisibleItems(in: displayedItems) ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) { toggleSelectAll(in: displayedItems) }
                    }
                    .tint(nil)
                }
            }

            if category == .codes, !editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        TOTPCircularTimer(date: context.date, period: sharedCodePeriod)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }

            ToolbarItem(placement: .topBarTrailing) {
                selectionModeButton
                    .tint(nil)
            }

            if !editMode.isEditing {
                ToolbarItem(placement: .bottomBar) {
                    sortMenu
                        .tint(nil)
                }

                ToolbarSpacer(.flexible, placement: .bottomBar)

                if !usesColumnSelection {
                    // iOS 26 renders this as the native bottom search pill.
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)

                    ToolbarSpacer(.flexible, placement: .bottomBar)
                }

                ToolbarItem(placement: .bottomBar) {
                    addItemButton
                        .tint(nil)
                }
            }

            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        pendingArchive = selectedItems
                        showingArchiveConfirmation = !pendingArchive.isEmpty
                    } label: {
                        Label(bulkSecondaryTitle, systemImage: bulkSecondaryIcon)
                    }
                    .disabled(selection.isEmpty)
                    .tint(nil)
                    .confirmationDialog(
                        archiveConfirmationTitle,
                        isPresented: bulkArchiveConfirmationBinding,
                        titleVisibility: .visible,
                        actions: archiveConfirmationActions,
                        message: archiveConfirmationMessage
                    )

                    Spacer()

                    Button(role: .destructive) {
                        pendingDeletion = selectedItems
                        showingDeleteConfirmation = !pendingDeletion.isEmpty
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                    .tint(nil)
                    .confirmationDialog(
                        deleteConfirmationTitle,
                        isPresented: bulkDeleteConfirmationBinding,
                        titleVisibility: .visible,
                        actions: deleteConfirmationActions,
                        message: deleteConfirmationMessage
                    )
                }
            }
        }
        .alert(rowAlertTitle, isPresented: $showingRowAlert) {
            if case .some(.delete(_)) = pendingRowAction {
                Button(rowDeleteActionTitle, role: .destructive) {
                    confirmPendingRowDelete()
                }
            } else if case .some(.archive(_)) = pendingRowAction {
                Button(rowArchiveActionTitle) {
                    confirmPendingRowArchive()
                }
            }
            Button("Cancel", role: .cancel) { pendingRowAction = nil }
        } message: {
            Text(rowAlertMessage)
        }
        .sheet(isPresented: $showingAddItem) {
            AddEditVaultItemView(
                prefilledType: filter.newItemType,
                prefilledFolder: filter.newItemFolder
            )
            .environmentObject(store)
        }
    }

    private var sharedCodePeriod: Int {
        liveItems.compactMap(\.totpSecret).first.map(TOTPGenerator.period(secret:)) ?? 30
    }

    private var addItemButton: some View {
        Button { showingAddItem = true } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add vault item")
    }

    @ViewBuilder
    private var selectionModeButton: some View {
        if usesColumnSelection, editMode.isEditing {
            Button(action: toggleSelectionMode) {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Done")
        } else {
            Button(editMode.isEditing ? "Done" : "Select", action: toggleSelectionMode)
                .disabled(liveItems.isEmpty)
        }
    }

    private func toggleSelectionMode() {
        withAnimation(.snappy) {
            if editMode.isEditing {
                editMode = .inactive
                selection.removeAll()
            } else {
                editMode = .active
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort vault items", selection: $sortOrder) {
                ForEach(VaultSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.icon)
                        .tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort vault items")
    }

    @ViewBuilder
    private func listSections(_ displayedItems: [VaultItem]) -> some View {
        if category == .security, !editMode.isEditing {
            Section {
                SecurityInformationCard()
                    .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }

        if displayedItems.isEmpty {
            Section {
                EmptyStateView(
                    icon: searchText.isEmpty ? "checkmark.shield.fill" : "magnifyingglass",
                    title: L10n.string(searchText.isEmpty ? "No Recommendations" : "No Results"),
                    message: searchText.isEmpty
                        ? L10n.string("No security issues were found in your active vault.")
                        : L10n.format("No security recommendations match “%@”.", searchText)
                )
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        } else {
            Section {
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    let isSelected = isRowSelected(item)
                    let nextIsSelected = index + 1 < displayedItems.count
                        && isRowSelected(displayedItems[index + 1])

                    row(for: item, isSelected: isSelected)
                        .tag(item.id)
                        .listRowBackground(
                            selectionBackground(
                                at: index,
                                item: item,
                                displayedItems: displayedItems
                            )
                        )
                        .listRowSeparator(
                            isSelected || nextIsSelected ? .hidden : .visible
                        )
                        // Every row's separator starts at the same place —
                        // just past the thumbnail — instead of some spanning
                        // the full width and some being inset.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            Self.separatorInset
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteButton(for: item)
                            archiveButton(for: item)
                        }
                        .contextMenu {
                            archiveButton(for: item)
                            deleteButton(for: item)
                        }
                }
            }
            // No hairline above the first row.
            .listSectionSeparator(.hidden, edges: .top)
        }
    }

    /// Thumbnail width (42) plus the row's leading stack spacing (13).
    private static let separatorInset: CGFloat = 55

    @ViewBuilder
    private func row(for item: VaultItem, isSelected: Bool) -> some View {
        if editMode.isEditing, usesColumnSelection {
            Button {
                withAnimation(.snappy) {
                    if selection.contains(item.id) {
                        selection.remove(item.id)
                    } else {
                        selection.insert(item.id)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(item.id) ? Color.white : Color.secondary)
                        .accessibilityHidden(true)

                    collectionRowContent(for: item, isSelected: selection.contains(item.id))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityValue(selection.contains(item.id) ? "Selected" : "Not selected")
        } else if editMode.isEditing {
            collectionRowContent(for: item)
        } else if category == .codes, let secret = item.totpSecret {
            TOTPItemRow(
                item: item,
                secret: secret,
                isSelected: isSelected,
                onSelect: usesColumnSelection ? { store.selectedItemID = item.id } : nil
            )
        } else if usesColumnSelection {
            Button {
                store.selectedItemID = item.id
            } label: {
                collectionRowContent(for: item, isSelected: isSelected)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item.id) {
                collectionRowContent(for: item, isSelected: isSelected)
            }
        }
    }

    private func isRowSelected(_ item: VaultItem) -> Bool {
        guard usesColumnSelection else { return false }
        return editMode.isEditing
            ? selection.contains(item.id)
            : store.selectedItemID == item.id
    }

    @ViewBuilder
    private func collectionRowContent(for item: VaultItem, isSelected: Bool = false) -> some View {
        if category == .security {
            SecurityRecommendationRow(item: item, isSelected: isSelected)
        } else {
            VaultItemRow(item: item, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func selectionBackground(
        at index: Int,
        item: VaultItem,
        displayedItems: [VaultItem]
    ) -> some View {
        if isRowSelected(item) {
            let previousIsSelected = index > 0 && isRowSelected(displayedItems[index - 1])
            let nextIsSelected = index + 1 < displayedItems.count
                && isRowSelected(displayedItems[index + 1])

            UnevenRoundedRectangle(
                topLeadingRadius: previousIsSelected ? 0 : 22,
                bottomLeadingRadius: nextIsSelected ? 0 : 22,
                bottomTrailingRadius: nextIsSelected ? 0 : 22,
                topTrailingRadius: previousIsSelected ? 0 : 22,
                style: .continuous
            )
            .fill(Color.accentColor)
            .padding(.horizontal, 12)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func archiveButton(for item: VaultItem) -> some View {
        if !item.isDeleted {
            Button {
                requestRowAction(.archive(item.id))
            } label: {
                Label(item.isArchived ? "Unarchive" : "Archive", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.orange)
        } else {
            Button {
                requestRowAction(.archive(item.id))
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
    }

    private func deleteButton(for item: VaultItem) -> some View {
        Button(role: .destructive) {
            requestRowAction(.delete(item.id))
        } label: {
            Label(item.isDeleted ? "Delete Permanently" : "Delete", systemImage: "trash")
        }
        .tint(.red)
    }

    private var pendingRowItem: VaultItem? {
        guard let id = pendingRowAction?.itemID else { return nil }
        return store.items.first { $0.id == id }
    }

    private var rowAlertTitle: String {
        guard let item = pendingRowItem else { return L10n.string("Vault Item") }
        switch pendingRowAction {
        case .some(.delete(_)):
            return L10n.string(item.isDeleted ? "Delete permanently?" : "Delete item?")
        case .some(.archive(_)):
            if item.isDeleted { return L10n.string("Restore item?") }
            return L10n.string(item.isArchived ? "Unarchive item?" : "Archive item?")
        case nil:
            return L10n.string("Vault Item")
        }
    }

    private var rowDeleteActionTitle: String {
        L10n.string(pendingRowItem?.isDeleted == true ? "Delete Permanently" : "Delete")
    }

    private var rowArchiveActionTitle: String {
        guard let item = pendingRowItem else { return L10n.string("Continue") }
        if item.isDeleted { return L10n.string("Restore") }
        return L10n.string(item.isArchived ? "Unarchive" : "Archive")
    }

    private var rowAlertMessage: String {
        guard let item = pendingRowItem else { return "" }
        switch pendingRowAction {
        case .some(.delete(_)):
            return L10n.string(item.isDeleted ? "This cannot be undone." : "You can restore this item later from Deleted.")
        case .some(.archive(_)):
            return L10n.format("This action applies to %@.", item.name)
        case nil:
            return ""
        }
    }

    private func requestRowAction(_ action: VaultRowAction) {
        pendingRowAction = action
        showingRowAlert = false
        Task { @MainActor in
            // The swipe row is transient while its actions close. Wait until
            // that animation completes, then present from this stable screen.
            try? await Task.sleep(for: .milliseconds(400))
            guard pendingRowAction == action, pendingRowItem != nil else {
                pendingRowAction = nil
                return
            }
            showingRowAlert = true
        }
    }

    private func confirmPendingRowDelete() {
        guard let item = pendingRowItem else { return }
        pendingRowAction = nil
        Task {
            if item.isDeleted { await store.permanentlyDelete(item) }
            else { await store.trash(item) }
        }
    }

    private func confirmPendingRowArchive() {
        guard let item = pendingRowItem else { return }
        pendingRowAction = nil
        Task {
            if item.isDeleted { await store.restore(item) }
            else if item.isArchived { await store.unarchive(item) }
            else { await store.archive(item) }
        }
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

    private func confirmArchiveAction() {
        let values = pendingArchive
        pendingArchive = []
        showingArchiveConfirmation = false
        finishSelectionMode()
        Task {
            for item in values {
                if item.isDeleted { await store.restore(item) }
                else if item.isArchived { await store.unarchive(item) }
                else { await store.archive(item) }
            }
        }
    }

    private func confirmDeleteAction() {
        let values = pendingDeletion
        pendingDeletion = []
        showingDeleteConfirmation = false
        finishSelectionMode()
        Task {
            for item in values {
                if item.isDeleted { await store.permanentlyDelete(item) }
                else { await store.trash(item) }
            }
        }
    }

    private func finishSelectionMode() {
        withAnimation(.snappy) {
            selection.removeAll()
            editMode = .inactive
        }
    }

    private var deleteConfirmationTitle: String {
        L10n.string(pendingDeletion.allSatisfy(\.isDeleted)
            ? "Delete permanently?"
            : "Delete selected items?")
    }

    private var archiveConfirmationTitle: String {
        let target = pendingArchive.count == 1 ? L10n.string("item") : L10n.string("selected items")
        if pendingArchive.allSatisfy(\.isDeleted) { return L10n.format("Restore %@?", target) }
        if pendingArchive.allSatisfy(\.isArchived) { return L10n.format("Unarchive %@?", target) }
        return L10n.format("Archive %@?", target)
    }

    @ViewBuilder
    private func deleteConfirmationActions() -> some View {
        Button(
            pendingDeletion.allSatisfy(\.isDeleted) ? "Delete Permanently" : "Delete",
            role: .destructive,
            action: confirmDeleteAction
        )
        Button("Cancel", role: .cancel) {
            pendingDeletion = []
            showingDeleteConfirmation = false
        }
    }

    @ViewBuilder
    private func deleteConfirmationMessage() -> some View {
        if pendingDeletion.allSatisfy(\.isDeleted) {
            Text("This cannot be undone.")
        } else {
            Text("You can restore these items later from Deleted.")
        }
    }

    @ViewBuilder
    private func archiveConfirmationActions() -> some View {
        Button(archiveConfirmationActionTitle, action: confirmArchiveAction)
        Button("Cancel", role: .cancel) {
            pendingArchive = []
            showingArchiveConfirmation = false
        }
    }

    private var archiveConfirmationActionTitle: String {
        if pendingArchive.allSatisfy(\.isDeleted) { return L10n.string("Restore") }
        if pendingArchive.allSatisfy(\.isArchived) { return L10n.string("Unarchive") }
        return L10n.string("Archive")
    }

    private func archiveConfirmationMessage() -> some View {
        Text(L10n.format("This action applies to %lld selected items.", pendingArchive.count))
    }

    private var bulkDeleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { showingDeleteConfirmation && editMode.isEditing },
            set: { newValue in
                showingDeleteConfirmation = newValue
                if !newValue { pendingDeletion = [] }
            }
        )
    }

    private var bulkArchiveConfirmationBinding: Binding<Bool> {
        Binding(
            get: { showingArchiveConfirmation && editMode.isEditing },
            set: { newValue in
                showingArchiveConfirmation = newValue
                if !newValue { pendingArchive = [] }
            }
        )
    }

    private func visibleItemIDs(in displayedItems: [VaultItem]) -> Set<UUID> {
        Set(displayedItems.map(\.id))
    }

    private func hasSelectedAllVisibleItems(in displayedItems: [VaultItem]) -> Bool {
        let visibleItemIDs = visibleItemIDs(in: displayedItems)
        return !visibleItemIDs.isEmpty && visibleItemIDs.isSubset(of: selection)
    }

    private func toggleSelectAll(in displayedItems: [VaultItem]) {
        let visibleItemIDs = visibleItemIDs(in: displayedItems)
        if !visibleItemIDs.isEmpty, visibleItemIDs.isSubset(of: selection) {
            selection.subtract(visibleItemIDs)
        } else {
            selection.formUnion(visibleItemIDs)
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

private struct SecurityInformationCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Security Recommendations", systemImage: "checkmark.shield.fill")
                .font(.body.bold())
                .foregroundStyle(Color.vaultBlue)

            Text("Vaultwarden highlights passwords that may be exposed, weak, reused, or used on unsecured websites so you can update them quickly.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct SecurityRecommendationRow: View {
    @EnvironmentObject private var store: AppStore
    let item: VaultItem
    var isSelected = false

    private var recommendation: (text: String, color: Color) {
        if item.risks.contains(.exposed) {
            return ("Compromised password", .vaultRed)
        }
        if item.risks.contains(.weak) {
            return ("Weak password", .vaultRed)
        }
        if item.risks.contains(.reused) {
            return ("Reused password", .secondary)
        }
        if item.risks.contains(.unsecured) {
            return ("Unsecured website", .vaultOrange)
        }
        return ("Review security", .secondary)
    }

    var body: some View {
        HStack(spacing: 13) {
            VaultItemThumbnail(
                item: item,
                showsWebsiteIcon: store.settings.showFavicons,
                serverURL: store.authenticatedSession?.serverURL
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Text(recommendation.text)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : recommendation.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct VaultItemRow: View {
    @EnvironmentObject private var store: AppStore
    let item: VaultItem
    var isSelected = false

    var body: some View {
        HStack(spacing: 13) {
            VaultItemThumbnail(
                item: item,
                showsWebsiteIcon: store.settings.showFavicons,
                serverURL: store.authenticatedSession?.serverURL
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.vaultYellow)
                    }
                }
                Text(item.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                if item.passkeyCount > 0 { Image(systemName: "person.badge.key.fill") }
                if item.totpSecret != nil { Image(systemName: "lock.rotation") }
                if item.organization != nil { Image(systemName: "person.2.fill") }
            }
            .font(.caption)
            .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
        }
        .padding(.vertical, 7)
    }

}

private struct VaultItemThumbnail: View {
    let item: VaultItem
    let showsWebsiteIcon: Bool
    let serverURL: URL?
    var size: CGFloat = 42
    @State private var image: UIImage?

    private var taskID: String {
        "\(showsWebsiteIcon)|\(serverURL?.absoluteString ?? "")|\(item.uri)"
    }

    var body: some View {
        Group {
            if item.type != .login {
                Image(systemName: item.type.icon)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(iconColor.gradient)
            } else if showsWebsiteIcon, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
                    .background(Color.white)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(iconColor.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: taskID) {
            image = nil
            guard showsWebsiteIcon,
                  item.type == .login,
                  !item.uri.isEmpty,
                  let serverURL,
                  let data = await WebsiteIconRepository.shared.iconData(
                    website: item.uri,
                    serverURL: serverURL
                  ) else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }

    private var initial: String {
        String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?")
            .uppercased()
    }

    private var iconColor: Color {
        switch item.type {
        case .login: .vaultBlue
        case .secureNote: .vaultOrange
        case .card: .vaultCyan
        case .identity: .vaultGreen
        case .sshKey: .vaultRed
        }
    }
}

struct VaultItemDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let itemID: UUID
    @State private var revealPassword = false
    @State private var revealCardNumber = false
    @State private var revealSecurityCode = false
    @State private var revealIdentityNumber = false
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false

    private var item: VaultItem? { store.items.first { $0.id == itemID } }

    var body: some View {
        Group {
            if let item, isEditing {
                // Editing happens on this screen rather than in a sheet. The
                // `.id` keeps the editor's field state tied to the item.
                AddEditVaultItemView(
                    existingItem: item,
                    presentation: .inline,
                    onFinish: { withAnimation(.snappy) { isEditing = false } }
                )
                .id(item.id)
                .transition(.opacity)
                // Suppresses both the back chevron and the swipe-to-pop gesture,
                // which would otherwise abandon the edit without asking.
                .navigationBarBackButtonHidden(true)
            } else if let item {
                List {
                    Section {
                        HStack(spacing: 16) {
                            VaultItemThumbnail(
                                item: item,
                                showsWebsiteIcon: store.settings.showFavicons,
                                serverURL: store.authenticatedSession?.serverURL,
                                size: 54
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.title2.bold())
                                Text(item.type.localizedTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    if item.type == .login {
                        Section {
                            SecretFieldRow(title: "Username", value: item.username, revealed: true)
                            if !item.password.isEmpty {
                                SecretFieldRow(title: "Password", value: item.password, revealed: revealPassword) {
                                    revealPassword.toggle()
                                }
                            }
                        } header: {
                            Text("Credentials")
                        } footer: {
                            if !item.password.isEmpty {
                                PasswordBreachFooter(password: item.password)
                            }
                        }

                        if let secret = item.totpSecret {
                            Section("Verification Code") {
                                TOTPCodeView(secret: secret)
                            }
                        }

                        if item.passkeyCount > 0 {
                            Section {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.title2)
                                        .foregroundStyle(Color.vaultGreen)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L10n.format("%lld passkeys stored", item.passkeyCount))
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text(L10n.format(
                                            "Passkeys are a secure way to sign in using %@ or your device passcode. They provide stronger phishing resistance than traditional passwords.",
                                            BiometricAuthenticator.displayName
                                        ))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }

                        if !item.websiteURIs.isEmpty {
                            Section("Websites (URI)") {
                                ForEach(Array(item.websiteURIs.enumerated()), id: \.offset) { index, uri in
                                    HStack(spacing: 12) {
                                        Text(uri)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)

                                        if let url = item.websiteURL(for: uri) {
                                            Link(destination: url) {
                                                Label("Open Website", systemImage: "safari")
                                                    .labelStyle(.iconOnly)
                                            }
                                            .accessibilityLabel(
                                                index == 0 ? "Open Website" : "Open Website \(index + 1)"
                                            )
                                            .fixedSize()
                                        }

                                        AnimatedCopyButton(
                                            value: uri,
                                            accessibilityName: index == 0 ? "website URI" : "website URI \(index + 1)"
                                        )
                                        .buttonStyle(.borderless)
                                        .fixedSize()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else if item.type == .card, let card = item.card {
                        Section("Card") {
                            if !card.cardholderName.isEmpty {
                                DetailValueRow(title: "Cardholder", value: card.cardholderName)
                            }
                            if !card.brand.isEmpty {
                                DetailValueRow(title: "Brand", value: card.brand, canCopy: false)
                            }
                            if !card.number.isEmpty {
                                SecretFieldRow(
                                    title: "Number",
                                    value: revealCardNumber ? card.number : card.maskedNumber,
                                    revealed: true,
                                    copyValue: card.number
                                ) {
                                    revealCardNumber.toggle()
                                }
                            }
                            if !card.securityCode.isEmpty {
                                SecretFieldRow(
                                    title: "Security code",
                                    value: card.securityCode,
                                    revealed: revealSecurityCode
                                ) {
                                    revealSecurityCode.toggle()
                                }
                            }
                        }

                        Section("Validity") {
                            DetailValueRow(title: "Expires", value: card.expirationDisplay, canCopy: false)
                            let validFrom = [card.validFromMonth, card.validFromYear].filter { !$0.isEmpty }.joined(separator: "/")
                            if !validFrom.isEmpty {
                                DetailValueRow(title: "Valid from", value: validFrom, canCopy: false)
                            }
                        }
                    } else if item.type == .identity, let identity = item.identity {
                        Section("Personal Information") {
                            if !identity.fullName.isEmpty {
                                DetailValueRow(title: "Full name", value: identity.fullName)
                            }
                            if !identity.username.isEmpty {
                                DetailValueRow(title: "Username", value: identity.username)
                            }
                            if !identity.company.isEmpty {
                                DetailValueRow(title: "Company", value: identity.company)
                            }
                        }

                        if !identity.email.isEmpty || !identity.phone.isEmpty {
                            Section("Contact") {
                                if !identity.email.isEmpty {
                                    DetailValueRow(title: "Email", value: identity.email)
                                }
                                if !identity.phone.isEmpty {
                                    DetailValueRow(title: "Phone", value: identity.phone)
                                }
                            }
                        }

                        if !identity.socialSecurityNumber.isEmpty || !identity.passportNumber.isEmpty || !identity.licenseNumber.isEmpty {
                            Section("Identification") {
                                if !identity.socialSecurityNumber.isEmpty {
                                    SecretFieldRow(
                                        title: "Social security number",
                                        value: identity.socialSecurityNumber,
                                        revealed: revealIdentityNumber
                                    ) {
                                        revealIdentityNumber.toggle()
                                    }
                                }
                                if !identity.passportNumber.isEmpty {
                                    DetailValueRow(title: "Passport number", value: identity.passportNumber)
                                }
                                if !identity.licenseNumber.isEmpty {
                                    DetailValueRow(title: "License number", value: identity.licenseNumber)
                                }
                            }
                        }

                        if !identity.address1.isEmpty || !identity.city.isEmpty || !identity.country.isEmpty {
                            Section("Address") {
                                if !identity.address1.isEmpty {
                                    DetailValueRow(title: "Address line 1", value: identity.address1)
                                }
                                if !identity.address2.isEmpty {
                                    DetailValueRow(title: "Address line 2", value: identity.address2)
                                }
                                if !identity.city.isEmpty {
                                    DetailValueRow(title: "City", value: identity.city)
                                }
                                if !identity.state.isEmpty {
                                    DetailValueRow(title: "State / Province", value: identity.state)
                                }
                                if !identity.postalCode.isEmpty {
                                    DetailValueRow(title: "Postal code", value: identity.postalCode)
                                }
                                if !identity.country.isEmpty {
                                    DetailValueRow(title: "Country", value: identity.country)
                                }
                            }
                        }
                    }

                    if !item.notes.isEmpty {
                        Section("Notes") { Text(item.notes) }
                    }

                    if !item.customFields.isEmpty {
                        Section("Custom Fields") {
                            ForEach(item.customFields) { field in
                                CustomFieldDetailRow(field: field, item: item)
                            }
                        }
                    }

                    if let folder = item.folder {
                        Section("Location") { LabeledContent("Folder", value: folder) }
                    }
                    if let organization = item.organization {
                        Section("Sharing") { LabeledContent("Organization", value: organization) }
                    }

                    if !item.risks.isEmpty {
                        Section("Security") {
                            ForEach(Array(item.risks), id: \.self) { risk in
                                Label(risk.localizedTitle, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.vaultRed)
                            }
                        }
                    }

                    Section {
                        if item.isDeleted {
                            Button("Restore Item") { Task { await store.restore(item) } }
                            Button("Delete Permanently", role: .destructive) { showDeleteConfirmation = true }
                                .confirmationDialog(
                                    "Delete permanently?",
                                    isPresented: $showDeleteConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete Permanently", role: .destructive) {
                                        Task { await deleteAndLeaveDetail(item, permanently: true) }
                                    }
                                    Button("Cancel", role: .cancel) { }
                                } message: {
                                    Text("This cannot be undone.")
                                }
                        } else if item.isArchived {
                            Button("Unarchive Item") { showArchiveConfirmation = true }
                                .confirmationDialog(
                                    "Unarchive item?",
                                    isPresented: $showArchiveConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Unarchive") { Task { await store.unarchive(item) } }
                                    Button("Cancel", role: .cancel) { }
                                }
                            detailMoveToDeletedButton(item)
                        } else {
                            Button("Archive Item") { showArchiveConfirmation = true }
                                .confirmationDialog(
                                    "Archive item?",
                                    isPresented: $showArchiveConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Archive") { Task { await store.archive(item) } }
                                    Button("Cancel", role: .cancel) { }
                                }
                            detailMoveToDeletedButton(item)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.format("Created %@", (item.createdAt ?? item.updatedAt).formatted(date: .abbreviated, time: .shortened)))
                            Text(L10n.format("Last edited %@", item.updatedAt.formatted(date: .abbreviated, time: .shortened)))
                        }
                        .textCase(nil)
                    }
                }
                // The item name already appears in the detail header. Keep the
                // split-view toolbar free for Edit and Search, like Passwords.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !item.isDeleted {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Edit") {
                                withAnimation(.snappy) { isEditing = true }
                            }
                            .tint(nil)
                        }
                    }
                }
            } else {
                EmptyStateView(icon: "questionmark.folder", title: "Item unavailable", message: "This item may have been deleted.")
            }
        }
    }

    private func detailMoveToDeletedButton(_ item: VaultItem) -> some View {
        Button("Move to Deleted", role: .destructive) {
            showDeleteConfirmation = true
        }
        .confirmationDialog(
            "Move item to Deleted?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Deleted", role: .destructive) {
                Task { await deleteAndLeaveDetail(item, permanently: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can restore this item later from Deleted.")
        }
    }

    @MainActor
    private func deleteAndLeaveDetail(_ item: VaultItem, permanently: Bool) async {
        let didDelete = if permanently {
            await store.permanentlyDelete(item)
        } else {
            await store.trash(item)
        }
        guard didDelete else { return }

        if store.selectedItemID == item.id {
            store.selectedItemID = nil
        }
        if horizontalSizeClass == .compact {
            dismiss()
        }
    }
}

private struct PasswordBreachFooter: View {
    let password: String
    @State private var state: BreachCheckState = .idle

    private enum BreachCheckState: Equatable {
        case idle
        case checking
        case safe
        case exposed(Int)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                Task { await checkPassword() }
            } label: {
                HStack(spacing: 7) {
                    if state == .checking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                    Text(state == .checking ? "Checking…" : "Check password for data breaches")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.vaultBlue)
            .disabled(password.isEmpty || state == .checking)

            switch state {
            case .safe:
                Label("Not found in the known breached-password data set.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(Color.vaultGreen)
            case let .exposed(count):
                Label(
                    L10n.format("Found %@ times. Change this password as soon as possible.", count.formatted()),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(Color.vaultRed)
            case .failed:
                Label("The check could not be completed. Try again when online.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Color.vaultRed)
            case .idle, .checking:
                Text("Uses Have I Been Pwned k-anonymity. Only a five-character hash prefix is sent; the password stays on this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .textCase(nil)
    }

    @MainActor
    private func checkPassword() async {
        guard !password.isEmpty, state != .checking else { return }
        state = .checking
        do {
            switch try await PasswordBreachChecker.check(password) {
            case .notFound: state = .safe
            case let .exposed(count): state = .exposed(count)
            }
        } catch {
            state = .failed
        }
    }
}

private struct DetailValueRow: View {
    let title: String
    let value: String
    var canCopy = true
    var localizesTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localizesTitle ? L10n.string(title) : title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if canCopy {
                    AnimatedCopyButton(
                        value: value,
                        accessibilityName: localizesTitle ? L10n.string(title) : title
                    )
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct CustomFieldDetailRow: View {
    let field: VaultCustomField
    let item: VaultItem
    @State private var revealed = false

    private var resolvedValue: String {
        guard field.type == .linked else { return field.value }
        return field.value == "password" ? item.password : item.username
    }

    var body: some View {
        switch field.type {
        case .boolean:
            LabeledContent(field.name) {
                Label(field.value == "true" ? "Yes" : "No", systemImage: field.value == "true" ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(field.value == "true" ? Color.vaultGreen : .secondary)
            }
        case .hidden:
            SecretFieldRow(
                title: field.name,
                value: resolvedValue,
                revealed: revealed,
                toggleReveal: { revealed.toggle() },
                localizesTitle: false
            )
        case .linked where field.value == "password":
            SecretFieldRow(
                title: field.name,
                value: resolvedValue,
                revealed: revealed,
                toggleReveal: { revealed.toggle() },
                localizesTitle: false
            )
        case .text, .linked:
            DetailValueRow(title: field.name, value: resolvedValue, localizesTitle: false)
        }
    }
}

private struct SecretFieldRow: View {
    let title: String
    let value: String
    let revealed: Bool
    var copyValue: String? = nil
    var toggleReveal: (() -> Void)?
    var localizesTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localizesTitle ? L10n.string(title) : title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(revealed ? value : String(repeating: "•", count: max(10, min(value.count, 18))))
                    .font(.body.monospaced())
                    .lineLimit(1)
                Spacer()
                if let toggleReveal {
                    Button(action: toggleReveal) {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                AnimatedCopyButton(
                    value: copyValue ?? value,
                    accessibilityName: localizesTitle ? L10n.string(title) : title
                )
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct TOTPCodeView: View {
    let secret: String
    @State private var copied = false
    @State private var copySequence = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let code = TOTPGenerator.code(secret: secret, date: context.date) ?? "------"
            Button {
                copy(code)
            } label: {
                HStack {
                    Text(code.chunked(every: 3))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Spacer()
                    TOTPCircularTimer(date: context.date, period: TOTPGenerator.period(secret: secret))
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(copied ? Color.vaultGreen : Color.vaultBlue)
                        .contentTransition(.symbolEffect(.replace))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                copied
                    ? L10n.string("Verification code copied")
                    : L10n.format("Copy verification code %@", code)
            )
        }
    }

    private func copy(_ code: String) {
        Clipboard.copy(code)
        copySequence += 1
        let currentSequence = copySequence
        withAnimation(.snappy) { copied = true }

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard copySequence == currentSequence else { return }
            withAnimation(.snappy) { copied = false }
        }
    }
}

private struct TOTPItemRow: View {
    @EnvironmentObject private var store: AppStore
    let item: VaultItem
    let secret: String
    var isSelected = false
    var onSelect: (() -> Void)?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let code = TOTPGenerator.code(secret: secret, date: context.date) ?? "------"

            HStack(spacing: 12) {
                if let onSelect {
                    Button(action: onSelect) {
                        rowContent(code: code)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Value-based like every other compact-width row, so it
                    // feeds the same navigation destination.
                    NavigationLink(value: item.id) {
                        rowContent(code: code)
                    }
                    .buttonStyle(.plain)
                }

                AnimatedCopyButton(
                    value: code,
                    accessibilityName: "verification code",
                    color: isSelected ? .white : .vaultBlue,
                    copiedColor: isSelected ? .white : .vaultGreen
                )
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
        }
    }

    private func rowContent(code: String) -> some View {
        HStack(spacing: 12) {
            VaultItemThumbnail(
                item: item,
                showsWebsiteIcon: store.settings.showFavicons,
                serverURL: store.authenticatedSession?.serverURL
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(item.username.isEmpty ? item.displaySubtitle : item.username)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(code.chunked(every: 3))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentTransition(.numericText())
                .accessibilityLabel(L10n.format("Code %@", code))
        }
    }
}

private struct TOTPCircularTimer: View {
    let date: Date
    let period: Int

    private var periodSeconds: Double { Double(period) }

    private var remainingFraction: Double {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: periodSeconds)
        return max(0, min(1, (periodSeconds - elapsed) / periodSeconds))
    }

    private var secondsRemaining: Int {
        Int(ceil(remainingFraction * periodSeconds))
    }

    private var color: Color {
        secondsRemaining <= 5 ? .vaultRed : .vaultBlue
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: remainingFraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(secondsRemaining, format: .number)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("Code refreshes in %lld seconds", secondsRemaining))
    }
}

private enum AddEditCredentialField: Hashable {
    /// All non-generator inputs participate in the same focus state. This is
    /// important when the keyboard moves directly between fields: without it,
    /// SwiftUI can keep the old credential focus value and fail to rebuild the
    /// keyboard suggestion when Username or Password becomes active again.
    case nonCredential(UUID)
    case loginUsername
    case loginPassword
    case identityUsername

    var suggestionTitle: String {
        switch self {
        case .nonCredential:
            ""
        case .loginPassword:
            "Strong Password Suggestion"
        case .loginUsername, .identityUsername:
            "Username Suggestion"
        }
    }

    var supportsGeneratorSuggestion: Bool {
        switch self {
        case .nonCredential:
            false
        case .loginUsername, .loginPassword, .identityUsername:
            true
        }
    }
}

private struct AddEditFocusBindingKey: EnvironmentKey {
    static let defaultValue: FocusState<AddEditCredentialField?>.Binding? = nil
}

private extension EnvironmentValues {
    var addEditFocusBinding: FocusState<AddEditCredentialField?>.Binding? {
        get { self[AddEditFocusBindingKey.self] }
        set { self[AddEditFocusBindingKey.self] = newValue }
    }
}

/// Installs a non-blocking tap recognizer on the editor's window. Taps on an
/// actual text input are ignored so field-to-field focus keeps working; every
/// other tap ends editing while still reaching the tapped control.
private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.attachWhenReady(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void
        private weak var attachedWindow: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func attachWhenReady(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                guard attachedWindow !== window else { return }
                detach()
                window.addGestureRecognizer(recognizer)
                attachedWindow = window
            }
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = nil
        }

        @objc private func handleTap() {
            attachedWindow?.endEditing(true)
            onDismiss()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView: UIView? = touch.view
            while let currentView = touchedView {
                if currentView is UITextField
                    || currentView is UITextView
                    || currentView is UIControl
                    || currentView.accessibilityIdentifier == "credentialSuggestionPanel" {
                    return false
                }
                touchedView = currentView.superview
            }
            return true
        }
    }
}

private struct CredentialKeyboardSuggestion: View {
    let title: String
    let value: String
    let onUse: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onUse) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.monospaced().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Use %@", L10n.string(title).lowercased()))
            .accessibilityValue(value)

            Divider()
                .frame(height: 34)

            Button(action: onCustomize) {
                Image(systemName: "wand.and.sparkles")
                    .frame(width: 32, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.vaultBlue)
            .accessibilityLabel("Open generator")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LabeledFormField: View {
    @Environment(\.addEditFocusBinding) private var inheritedFocusBinding
    @State private var focusID = UUID()
    let title: String
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let showsRevealButton: Bool
    let focusBinding: FocusState<AddEditCredentialField?>.Binding?
    let focusValue: AddEditCredentialField?
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let capitalization: TextInputAutocapitalization?
    let autocorrectionDisabled: Bool
    @State private var isRevealed = false

    init(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        showsRevealButton: Bool = false,
        focusBinding: FocusState<AddEditCredentialField?>.Binding? = nil,
        focusValue: AddEditCredentialField? = nil,
        keyboardType: UIKeyboardType = .default,
        textContentType: UITextContentType? = nil,
        capitalization: TextInputAutocapitalization? = nil,
        autocorrectionDisabled: Bool = false
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.showsRevealButton = showsRevealButton
        self.focusBinding = focusBinding
        self.focusValue = focusValue
        self.keyboardType = keyboardType
        self.textContentType = textContentType
        self.capitalization = capitalization
        self.autocorrectionDisabled = autocorrectionDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                focusedInput
                .font(.body)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled(autocorrectionDisabled)

                if isSecure && showsRevealButton {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        L10n.format(
                            isRevealed ? "Hide %@" : "Show %@",
                            L10n.string(title)
                        )
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var focusedInput: some View {
        if let binding = focusBinding ?? inheritedFocusBinding {
            input.focused(binding, equals: focusValue ?? .nonCredential(focusID))
        } else {
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        if isSecure && !isRevealed {
            SecureField(L10n.string(placeholder), text: $text)
        } else {
            TextField(L10n.string(placeholder), text: $text)
        }
    }
}

struct AddEditVaultItemView: View {
    /// `sheet` brings its own navigation stack and Cancel/Save titles.
    /// `inline` drops the stack so the editor can take over a detail screen
    /// that is already inside one, and uses the compact ✕ / ✓ controls.
    enum Presentation {
        case sheet
        case inline
    }

    private struct EditableWebsiteURI: Identifiable {
        let id = UUID()
        var value: String
    }

    private struct EditableSnapshot: Equatable {
        let name: String
        let username: String
        let password: String
        let uris: [String]
        let type: VaultItemType
        let folder: String?
        let notes: String
        let isFavorite: Bool
        let totpSecret: String?
        let card: CardDetails?
        let identity: IdentityDetails?
        let customFields: [VaultCustomField]
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private let existingItem: VaultItem?
    private let existingID: UUID?
    private let presentation: Presentation
    /// Called instead of `dismiss()` when the editor is hosted inline.
    private let onFinish: (() -> Void)?
    @State private var name: String
    @State private var username: String
    @State private var password: String
    @State private var websiteURIs: [EditableWebsiteURI]
    @State private var type: VaultItemType
    @State private var folder: String
    @State private var notes: String
    @State private var isFavorite: Bool
    @State private var totpSecret: String
    @State private var card: CardDetails
    @State private var identity: IdentityDetails
    @State private var customFields: [VaultCustomField]
    @State private var showingGenerator = false
    @State private var showingUsernameGenerator = false
    @State private var showingTOTPScanner = false
    @State private var totpScanError: String?
    @State private var isSaving = false
    @State private var passwordSuggestion: String
    @State private var usernameSuggestion: String
    @State private var notesFocusID = UUID()
    @State private var isKeyboardVisible = false
    @FocusState private var focusedCredentialField: AddEditCredentialField?

    init(
        existingItem: VaultItem? = nil,
        prefilledPassword: String = "",
        prefilledName: String = "",
        prefilledUsername: String = "",
        prefilledTOTPSecret: String = "",
        prefilledType: VaultItemType = .login,
        prefilledFolder: String = "",
        presentation: Presentation = .sheet,
        onFinish: (() -> Void)? = nil
    ) {
        self.existingItem = existingItem
        existingID = existingItem?.id
        self.presentation = presentation
        self.onFinish = onFinish
        _name = State(initialValue: existingItem?.name ?? prefilledName)
        _username = State(initialValue: existingItem?.username ?? prefilledUsername)
        _password = State(initialValue: existingItem?.password ?? prefilledPassword)
        let initialURIs = existingItem?.websiteURIs ?? []
        _websiteURIs = State(
            initialValue: (initialURIs.isEmpty ? [""] : initialURIs)
                .map { EditableWebsiteURI(value: $0) }
        )
        _type = State(initialValue: existingItem?.type ?? prefilledType)
        _folder = State(initialValue: existingItem?.folder ?? prefilledFolder)
        _notes = State(initialValue: existingItem?.notes ?? "")
        _isFavorite = State(initialValue: existingItem?.isFavorite ?? false)
        _totpSecret = State(initialValue: existingItem?.totpSecret ?? prefilledTOTPSecret)
        _card = State(initialValue: existingItem?.card ?? CardDetails())
        _identity = State(initialValue: existingItem?.identity ?? IdentityDetails())
        _customFields = State(initialValue: existingItem?.customFields ?? [])
        _passwordSuggestion = State(
            initialValue: PasswordGenerator.password(
                length: 20,
                uppercase: true,
                numbers: true,
                symbols: true
            )
        )
        _usernameSuggestion = State(initialValue: PasswordGenerator.username())
    }

    var body: some View {
        switch presentation {
        case .sheet: NavigationStack { editor }
        case .inline: editor
        }
    }

    private var editor: some View {
        Form {
                Section {
                    if existingItem == nil {
                        Picker("Type", selection: $type) {
                            ForEach(VaultItemType.allCases.filter { $0 != .sshKey }) {
                                Text($0.localizedTitle).tag($0)
                            }
                        }
                    } else {
                        LabeledContent("Type", value: type.localizedTitle)
                    }
                    LabeledFormField("Name", text: $name, placeholder: "Enter item name", textContentType: .name)
                    Toggle("Favorite", isOn: $isFavorite)
                }

                if type == .login {
                    Section("Credentials") {
                        LabeledFormField(
                            "Username",
                            text: $username,
                            placeholder: "Enter username",
                            focusBinding: $focusedCredentialField,
                            focusValue: .loginUsername,
                            textContentType: .oneTimeCode,
                            capitalization: .never,
                            autocorrectionDisabled: true
                        )
                        LabeledFormField(
                            "Password",
                            text: $password,
                            placeholder: "Enter password",
                            isSecure: true,
                            showsRevealButton: true,
                            focusBinding: $focusedCredentialField,
                            focusValue: .loginPassword,
                            textContentType: .oneTimeCode,
                            capitalization: .never,
                            autocorrectionDisabled: true
                        )
                    }
                    Section("Websites (URI)") {
                        ForEach($websiteURIs) { $website in
                            HStack(alignment: .bottom, spacing: 12) {
                                LabeledFormField(
                                    "Website",
                                    text: $website.value,
                                    placeholder: "https://example.com",
                                    keyboardType: .URL,
                                    capitalization: .never,
                                    autocorrectionDisabled: true
                                )

                                if websiteURIs.count > 1 {
                                    Button(role: .destructive) {
                                        websiteURIs.removeAll { $0.id == website.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove website")
                                    .padding(.bottom, 2)
                                }
                            }
                        }

                        Button {
                            websiteURIs.append(EditableWebsiteURI(value: ""))
                        } label: {
                            Label("Add Website", systemImage: "plus.circle")
                        }
                    }
                    Section("Authenticator") {
                        LabeledFormField(
                            "TOTP Secret",
                            text: $totpSecret,
                            placeholder: "Optional",
                            capitalization: .characters,
                            autocorrectionDisabled: true
                        )
                        Button {
                            guard DataScannerViewController.isSupported,
                                  DataScannerViewController.isAvailable else {
                                totpScanError = "QR code scanning is not available on this device."
                                return
                            }
                            showingTOTPScanner = true
                        } label: {
                            Label("Scan", systemImage: "qrcode.viewfinder")
                        }
                    }
                } else if type == .card {
                    cardForm
                } else if type == .identity {
                    identityForm
                }

                Section("Organization") {
                    Picker("Folder", selection: $folder) {
                        Text("No Folder").tag("")
                        ForEach(store.folders) { Text($0.name).tag($0.name) }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .focused($focusedCredentialField, equals: .nonCredential(notesFocusID))
                        .frame(minHeight: 100)
                }

                customFieldsEditor
            }
            .environment(\.addEditFocusBinding, $focusedCredentialField)
            .background {
                KeyboardDismissTapInstaller {
                    focusedCredentialField = nil
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isKeyboardVisible, let activeCredentialField {
                    CredentialKeyboardSuggestion(
                        title: activeCredentialField.suggestionTitle,
                        value: suggestion(for: activeCredentialField),
                        onUse: { useSuggestion(for: activeCredentialField) },
                        onCustomize: { presentGenerator(for: activeCredentialField) }
                    )
                    .id(activeCredentialField)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                    .accessibilityIdentifier("credentialSuggestionPanel")
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { finish() } label: {
                        switch presentation {
                        case .sheet: Text("Cancel")
                        case .inline: Image(systemName: "xmark")
                        }
                    }
                    .accessibilityLabel("Cancel")
                    .tint(nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            switch presentation {
                            case .sheet: Text("Save")
                            case .inline: Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel("Save")
                    .buttonStyle(.borderedProminent)
                    .tint(nil)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingGenerator) {
                QuickPasswordGeneratorView { generated in
                    password = generated
                    passwordSuggestion = generated
                    showingGenerator = false
                }
            }
            .sheet(isPresented: $showingUsernameGenerator) {
                QuickUsernameGeneratorView { generated in
                    if type == .identity {
                        identity.username = generated
                    } else {
                        username = generated
                    }
                    usernameSuggestion = generated
                    showingUsernameGenerator = false
                }
            }
            .sheet(isPresented: $showingTOTPScanner) {
                NavigationStack {
                    TOTPQRCodeScannerView { scannedValue in
                        showingTOTPScanner = false
                        guard let url = URL(string: scannedValue),
                              OTPAuthSetupRequest.parse(url) != nil else {
                            totpScanError = "This QR code is not a valid TOTP authenticator setup."
                            return
                        }
                        totpSecret = scannedValue
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Authenticator Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingTOTPScanner = false }
                                .tint(nil)
                        }
                    }
                }
            }
            .alert(
                "Unable to Scan Code",
                isPresented: Binding(
                    get: { totpScanError != nil },
                    set: { if !$0 { totpScanError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { totpScanError = nil }
            } message: {
                Text(totpScanError ?? "Please try again.")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: focusedCredentialField) { oldValue, newValue in
                guard let newValue,
                      newValue.supportsGeneratorSuggestion,
                      newValue != oldValue else { return }
                refreshSuggestion(for: newValue)
            }
    }

    private var navigationTitleText: String {
        switch presentation {
        case .inline: ""
        case .sheet: L10n.string(existingID == nil ? "New Item" : "Edit Item")
        }
    }

    private var activeCredentialField: AddEditCredentialField? {
        switch focusedCredentialField {
        case .loginUsername, .loginPassword, .identityUsername:
            focusedCredentialField
        case .nonCredential, nil:
            nil
        }
    }

    private func presentGenerator(for field: AddEditCredentialField) {
        focusedCredentialField = nil
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            showingGenerator = true
        case .loginUsername, .identityUsername:
            showingUsernameGenerator = true
        }
    }

    private func suggestion(for field: AddEditCredentialField) -> String {
        switch field {
        case .nonCredential:
            ""
        case .loginPassword:
            passwordSuggestion
        case .loginUsername, .identityUsername:
            usernameSuggestion
        }
    }

    private func refreshSuggestion(for field: AddEditCredentialField) {
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            passwordSuggestion = PasswordGenerator.password(
                length: 20,
                uppercase: true,
                numbers: true,
                symbols: true
            )
        case .loginUsername, .identityUsername:
            usernameSuggestion = PasswordGenerator.username()
        }
    }

    private func useSuggestion(for field: AddEditCredentialField) {
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            password = passwordSuggestion
        case .loginUsername:
            username = usernameSuggestion
        case .identityUsername:
            identity.username = usernameSuggestion
        }
    }

    /// Inline hosts stay on screen, so hand control back to them instead of
    /// dismissing a presentation that does not exist.
    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    private var cardForm: some View {
        Group {
            Section("Card Details") {
                LabeledFormField("Cardholder Name", text: $card.cardholderName, placeholder: "Name on card", textContentType: .name)
                Picker("Brand", selection: $card.brand) {
                    ForEach(cardBrandOptions, id: \.self) { brand in
                        Text(brand.isEmpty ? "Select Brand" : brand).tag(brand)
                    }
                }
                LabeledFormField(
                    "Card Number",
                    text: $card.number,
                    placeholder: "Enter card number",
                    keyboardType: .numberPad,
                    textContentType: .creditCardNumber
                )
                LabeledFormField(
                    "Security Code",
                    text: $card.securityCode,
                    placeholder: "CVV / CVC",
                    isSecure: true,
                    keyboardType: .numberPad
                )
            }

            Section("Expiration") {
                HStack {
                    LabeledFormField("Month", text: $card.expirationMonth, placeholder: "MM", keyboardType: .numberPad)
                    Divider()
                    LabeledFormField("Year", text: $card.expirationYear, placeholder: "YYYY", keyboardType: .numberPad)
                }
                HStack {
                    LabeledFormField("Valid From Month", text: $card.validFromMonth, placeholder: "MM", keyboardType: .numberPad)
                    Divider()
                    LabeledFormField("Valid From Year", text: $card.validFromYear, placeholder: "YYYY", keyboardType: .numberPad)
                }
            }
        }
    }

    private var cardBrandOptions: [String] {
        var values = [
            "",
            "Visa",
            "Mastercard",
            "American Express",
            "Discover",
            "Diners Club",
            "JCB",
            "Maestro",
            "UnionPay",
            "RuPay",
            "Other"
        ]
        let existingBrand = card.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingBrand.isEmpty, !values.contains(existingBrand) {
            values.insert(existingBrand, at: values.count - 1)
        }
        return values
    }

    private var identityForm: some View {
        Group {
            Section("Personal Information") {
                Picker("Title", selection: $identity.title) {
                    ForEach(identityTitleOptions, id: \.self) { title in
                        Text(title.isEmpty ? "Select Title" : title).tag(title)
                    }
                }
                LabeledFormField("First Name", text: $identity.firstName, placeholder: "Enter first name", textContentType: .givenName)
                LabeledFormField("Middle Name", text: $identity.middleName, placeholder: "Optional", textContentType: .middleName)
                LabeledFormField("Last Name", text: $identity.lastName, placeholder: "Enter last name", textContentType: .familyName)
                LabeledFormField(
                    "Username",
                    text: $identity.username,
                    placeholder: "Enter username",
                    focusBinding: $focusedCredentialField,
                    focusValue: .identityUsername,
                    textContentType: .oneTimeCode,
                    capitalization: .never,
                    autocorrectionDisabled: true
                )
                LabeledFormField("Company", text: $identity.company, placeholder: "Enter company", textContentType: .organizationName)
            }

            Section("Contact") {
                LabeledFormField(
                    "Email",
                    text: $identity.email,
                    placeholder: "name@example.com",
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    capitalization: .never
                )
                LabeledFormField("Phone", text: $identity.phone, placeholder: "Enter phone number", keyboardType: .phonePad, textContentType: .telephoneNumber)
            }

            Section("Identification") {
                LabeledFormField("Social Security Number", text: $identity.socialSecurityNumber, placeholder: "Enter number", isSecure: true)
                LabeledFormField("Passport Number", text: $identity.passportNumber, placeholder: "Enter passport number", capitalization: .characters)
                LabeledFormField("License Number", text: $identity.licenseNumber, placeholder: "Enter license number", capitalization: .characters)
            }

            Section("Address") {
                LabeledFormField("Address Line 1", text: $identity.address1, placeholder: "Street address", textContentType: .streetAddressLine1)
                LabeledFormField("Address Line 2", text: $identity.address2, placeholder: "Apartment, suite, etc.", textContentType: .streetAddressLine2)
                LabeledFormField("City", text: $identity.city, placeholder: "Enter city", textContentType: .addressCity)
                LabeledFormField("State / Province", text: $identity.state, placeholder: "Enter state or province", textContentType: .addressState)
                LabeledFormField("Postal Code", text: $identity.postalCode, placeholder: "Enter postal code", textContentType: .postalCode)
                LabeledFormField("Country", text: $identity.country, placeholder: "Enter country", textContentType: .countryName)
            }
        }
    }

    private var identityTitleOptions: [String] {
        var values = ["", "Mr", "Mrs", "Ms", "Miss", "Dr", "Prof", "Mx"]
        let existingTitle = identity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingTitle.isEmpty, !values.contains(existingTitle) {
            values.append(existingTitle)
        }
        return values
    }

    private var customFieldsEditor: some View {
        Section("Custom Fields") {
            ForEach($customFields) { $field in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: field.type.icon)
                            .foregroundStyle(Color.vaultBlue)
                            .frame(width: 24)
                        LabeledFormField("Field Name", text: $field.name, placeholder: "Enter a label")
                        Menu {
                            Picker("Field type", selection: $field.type) {
                                ForEach(VaultCustomFieldType.allCases) { type in
                                    Label(type.localizedTitle, systemImage: type.icon).tag(type)
                                }
                            }
                        } label: {
                            Text(field.type.localizedTitle)
                                .font(.caption.weight(.semibold))
                        }
                    }

                    switch field.type {
                    case .text:
                        LabeledFormField("Value", text: $field.value, placeholder: "Enter value")
                    case .hidden:
                        LabeledFormField("Value", text: $field.value, placeholder: "Enter hidden value", isSecure: true)
                    case .boolean:
                        Toggle("Enabled", isOn: booleanBinding(for: $field.value))
                    case .linked:
                        Picker("Linked value", selection: $field.value) {
                            Text("Username").tag("username")
                            Text("Password").tag("password")
                        }
                        .pickerStyle(.segmented)
                    }

                    Button("Remove Field", role: .destructive) {
                        customFields.removeAll { $0.id == field.id }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 6)
            }

            Button {
                customFields.append(VaultCustomField())
            } label: {
                Label("Add Custom Field", systemImage: "plus.circle.fill")
            }
        }
    }

    private func booleanBinding(for value: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue == "true" },
            set: { value.wrappedValue = $0 ? "true" : "false" }
        )
    }

    private var draftItem: VaultItem {
        var item = existingItem ?? VaultItem(name: name)
        let normalizedURIs = websiteURIs
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.username = username
        item.password = password
        item.uri = normalizedURIs.first ?? ""
        item.additionalURIs = normalizedURIs.count > 1 ? Array(normalizedURIs.dropFirst()) : nil
        item.type = type
        item.folder = folder.isEmpty ? nil : folder
        item.notes = notes
        item.isFavorite = isFavorite
        item.totpSecret = totpSecret.isEmpty ? nil : totpSecret
        item.card = type == .card ? card : nil
        item.identity = type == .identity ? identity : nil
        item.customFields = customFields.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let existingID { item.id = existingID }
        return item
    }

    private func editableSnapshot(for item: VaultItem) -> EditableSnapshot {
        EditableSnapshot(
            name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: item.username,
            password: item.password,
            uris: item.websiteURIs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            type: item.type,
            folder: item.folder?.isEmpty == false ? item.folder : nil,
            notes: item.notes,
            isFavorite: item.isFavorite,
            totpSecret: item.totpSecret?.isEmpty == false ? item.totpSecret : nil,
            card: item.type == .card ? (item.card ?? CardDetails()) : nil,
            identity: item.type == .identity ? (item.identity ?? IdentityDetails()) : nil,
            customFields: item.customFields.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    private func save() async {
        let item = draftItem
        if let existingItem,
           editableSnapshot(for: item) == editableSnapshot(for: existingItem) {
            finish()
            return
        }

        isSaving = true
        defer { isSaving = false }
        if await store.save(item) {
            finish()
        }
    }
}

private struct TOTPQRCodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                hasScanned = true
                dataScanner.stopScanning()
                onScan(value)
                return
            }
        }
    }
}

private extension String {
    func chunked(every size: Int) -> String {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(size, distance(from: start, to: endIndex)))
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}
