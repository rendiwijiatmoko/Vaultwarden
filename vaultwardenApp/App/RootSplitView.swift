import SwiftUI

/// The adaptive shell for the whole authenticated app.
///
/// Both idioms show the same card dashboard. Compact width makes it the root of
/// a plain `NavigationStack`; regular width makes it the sidebar of a
/// `NavigationSplitView` with a list column and a detail column, opening on
/// "Login". Only the container and the way a card is activated differ.
struct RootSplitView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var path = NavigationPath()
    @State private var regularSearchText = ""
    @State private var regularBulkSelection = Set<UUID>()
    @State private var isRegularBulkSelecting = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactStack
            } else {
                regularSplit
            }
        }
        .task { selectDefaultSectionIfNeeded() }
        .onChange(of: horizontalSizeClass) { _, newValue in
            // A window resize or rotation swaps containers entirely. Carry the
            // user's place across instead of dumping them back at the root.
            if newValue == .compact {
                restoreCompactPath()
            } else {
                selectDefaultSectionIfNeeded()
            }
        }
    }

    private var compactStack: some View {
        NavigationStack(path: $path) {
            VaultHomeView(style: .dashboard)
                .navigationDestination(for: VaultFilter.self) { filter in
                    VaultCollectionView(filter: filter, usesColumnSelection: false)
                        // Mirrors the stack position into shared state so the
                        // split view can pick it up if the window widens.
                        .onAppear { store.selectedFilter = filter }
                }
                .navigationDestination(for: UUID.self) { itemID in
                    VaultItemDetailView(itemID: itemID)
                        .onAppear { store.selectedItemID = itemID }
                }
        }
    }

    private func restoreCompactPath() {
        var restored = NavigationPath()
        if let filter = store.selectedFilter { restored.append(filter) }
        if let itemID = store.selectedItemID { restored.append(itemID) }
        path = restored
    }

    private var regularSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VaultHomeView(style: .sidebar)
        } content: {
            if let filter = store.selectedFilter {
                // Fresh identity per section, otherwise the list's search text
                // and edit-mode selection leak across sections.
                VaultCollectionView(
                    filter: filter,
                    usesColumnSelection: true,
                    searchText: $regularSearchText,
                    onSelectionChange: updateRegularSelection
                )
                    .id(filter)
            } else {
                VaultColumnPlaceholder(
                    icon: "lock.rectangle.stack.fill",
                    title: "Your Vault",
                    message: "Pick a section in the sidebar to see the items it holds."
                )
            }
        } detail: {
            regularDetail
                // Search belongs to the detail column so it remains at the far
                // right of the split toolbar. A selected item's Edit action is
                // then placed immediately to its left by the system.
                .searchable(
                    text: $regularSearchText,
                    placement: .toolbar,
                    prompt: regularSearchPrompt
                )
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.selectedFilter) { _, _ in
            regularSearchText = ""
            updateRegularSelection([], false)
        }
    }

    @ViewBuilder
    private var regularDetail: some View {
        if isRegularBulkSelecting {
            let count = regularBulkSelection.count

            VaultColumnPlaceholder(
                icon: "checkmark.rectangle.stack.fill",
                title: L10n.format("%lld items selected", count),
                message: count == 0
                    ? L10n.string("Select one or more items from the list to use bulk actions.")
                    : L10n.string("Use the bottom toolbar to apply an action to every selected item.")
            )
        } else if let itemID = store.selectedItemID {
            // Without an explicit identity the reveal-password toggles stay
            // flipped when the selection moves to another item.
            VaultItemDetailView(itemID: itemID)
                .id(itemID)
        } else {
            let placeholder = regularEmptyDetail

            VaultColumnPlaceholder(
                icon: placeholder.icon,
                title: placeholder.title,
                message: placeholder.message
            )
        }
    }

    private var regularEmptyDetail: VaultDetailPlaceholder {
        guard let filter = store.selectedFilter else {
            return .init(
                icon: "lock.rectangle.stack.fill",
                title: "Your Vault",
                message: "Choose a section in the sidebar to browse its items."
            )
        }

        switch filter {
        case let .category(category):
            switch category {
            case .logins:
                return .init(icon: category.icon, title: "No Item Selected", message: "Choose an item to view its saved details.")
            case .passkeys:
                return .init(icon: category.icon, title: "No Passkey Selected", message: "Choose a passkey to view the account and sign-in details it protects.")
            case .codes:
                return .init(icon: category.icon, title: "No Code Selected", message: "Choose a verification code to view its account and one-time password.")
            case .cards:
                return .init(icon: category.icon, title: "No Card Selected", message: "Choose a card to view its saved payment details.")
            case .identities:
                return .init(icon: category.icon, title: "No Identity Selected", message: "Choose an identity to view its saved personal information.")
            case .sshKeys:
                return .init(icon: category.icon, title: "No SSH Key Selected", message: "Choose an SSH key to view its connection and key details.")
            case .secureNotes:
                return .init(icon: category.icon, title: "No Secure Note Selected", message: "Choose a secure note to view its protected contents.")
            case .security:
                return .init(icon: category.icon, title: "No Recommendation Selected", message: "Choose a security recommendation to review the affected item and suggested action.")
            case .archived:
                return .init(icon: category.icon, title: "No Archived Item Selected", message: "Choose an archived item to view or restore it.")
            case .deleted:
                return .init(icon: category.icon, title: "No Deleted Item Selected", message: "Choose a deleted item to restore it or remove it permanently.")
            }
        case .favorites:
            return .init(icon: filter.icon, title: "No Favorite Selected", message: "Choose a favorite item to view its saved details.")
        case .unfoldered:
            return .init(icon: filter.icon, title: "No Item Selected", message: "Choose an unfoldered item to view its saved details.")
        case let .folder(name):
            return .init(icon: filter.icon, title: "No Item Selected", message: L10n.format("Choose an item from %@ to view its saved details.", name))
        case .collection, .organization:
            return .init(icon: filter.icon, title: "No Shared Item Selected", message: L10n.format("Choose an item from %@ to view its shared details.", store.title(for: filter)))
        }
    }

    private var regularSearchPrompt: String {
        guard let filter = store.selectedFilter else { return L10n.string("Search") }
        return L10n.format("Search %@", store.title(for: filter).lowercased())
    }

    private func updateRegularSelection(_ selection: Set<UUID>, _ isEditing: Bool) {
        regularBulkSelection = selection
        isRegularBulkSelecting = isEditing

        guard isEditing else { return }
        store.selectedItemID = selection.count == 1 ? selection.first : nil
    }

    /// iPad (and any regular-width window) opens straight onto "Login". Compact
    /// width deliberately stays `nil` so the dashboard is the landing screen.
    private func selectDefaultSectionIfNeeded() {
        guard horizontalSizeClass == .regular, store.selectedFilter == nil else { return }
        store.selectedFilter = .login
    }
}

private struct VaultColumnPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        EmptyStateView(icon: icon, title: title, message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.vaultBackground)
    }
}

private struct VaultDetailPlaceholder {
    let icon: String
    let title: String
    let message: String
}

// MARK: - Vault home

enum VaultHomeStyle {
    /// iPhone: root of a navigation stack. Taps push; the bottom bar carries
    /// new folder, search and add.
    case dashboard
    /// iPad: the split view's sidebar column. Taps set the selection that
    /// drives the list column; search lives over the detail, while sort and add
    /// remain at opposite ends of the list column's bottom toolbar.
    case sidebar
}

/// The vault dashboard: a category grid followed by folders, shared groups and
/// hidden items. Identical content in both idioms.
struct VaultHomeView: View {
    /// Passed in rather than derived from `horizontalSizeClass`: content hosted
    /// in a split view column does not reliably report the window's size class,
    /// and guessing wrong here would render links that have no destination.
    let style: VaultHomeStyle

    @EnvironmentObject private var store: AppStore

    @State private var searchText = ""
    @State private var showingSettings = false
    @State private var showingGenerator = false
    @State private var showingSend = false
    @State private var showingAddItem = false
    @State private var showingAddFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingRename: VaultFolder?
    @State private var renameFolderName = ""
    @State private var folderPendingDeletion: VaultFolder?

    @State private var personalFoldersExpanded = true
    @State private var sharedVaultsExpanded = true
    @State private var hiddenItemsExpanded = false

    @Namespace private var transitions

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search only exists on the dashboard; the iPad list column has its own.
    private var isSearching: Bool { style == .dashboard && !trimmedQuery.isEmpty }

    private var visibleDashboardCategories: [VaultCategory] {
        VaultFilter.dashboardCategories.filter { category in
            category != .sshKeys || store.count(for: .category(category)) > 0
        }
    }

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else {
                dashboard
            }
        }
        .background(Color.vaultBackground)
        .navigationTitle(style == .sidebar ? "" : "Vault")
        .navigationBarTitleDisplayMode(style == .sidebar ? .inline : .large)
        .modifier(SearchableWhenEnabled(isEnabled: style == .dashboard, text: $searchText))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(store)
                .navigationTransition(.zoom(sourceID: HomeTransition.settings, in: transitions))
        }
        .sheet(isPresented: $showingGenerator) {
            GeneratorView()
                .environmentObject(store)
                .navigationTransition(.zoom(sourceID: HomeTransition.tools, in: transitions))
        }
        .sheet(isPresented: $showingSend) {
            SendView()
                .environmentObject(store)
                .navigationTransition(.zoom(sourceID: HomeTransition.tools, in: transitions))
        }
        .sheet(isPresented: $showingAddItem) {
            AddEditVaultItemView()
                .environmentObject(store)
                .navigationTransition(.zoom(sourceID: HomeTransition.addItem, in: transitions))
        }
        .alert("New Folder", isPresented: $showingAddFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolderName = ""
                Task { _ = await store.addFolder(named: name) }
            }
        } message: {
            Text("Folders organize your personal vault. They are not shared with organization members.")
        }
        .alert("Rename Folder", isPresented: renameFolderBinding) {
            TextField("Folder name", text: $renameFolderName)
            Button("Cancel", role: .cancel) { folderPendingRename = nil }
            Button("Save") {
                guard let folder = folderPendingRename else { return }
                let name = renameFolderName
                folderPendingRename = nil
                // `.folder` is keyed by name, so a rename would otherwise strand
                // the list column on a filter that matches nothing.
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if store.selectedFilter == .folder(folder.name), !trimmed.isEmpty {
                    store.selectedFilter = .folder(trimmed)
                }
                Task { _ = await store.renameFolder(folder, to: name) }
            }
        } message: {
            Text("Items in this folder will keep their assignment.")
        }
        .confirmationDialog(
            folderPendingDeletion.map { L10n.format("Delete %@?", $0.name) } ?? L10n.string("Delete Folder?"),
            isPresented: deleteFolderBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = folderPendingDeletion else { return }
                folderPendingDeletion = nil
                if store.selectedFilter == .folder(folder.name) { store.selectedFilter = nil }
                Task { await store.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: {
            Text("Vault items are kept and moved to Unfoldered.")
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    VaultSyncStatusText()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleDashboardCategories) { category in
                            let filter = VaultFilter.category(category)
                            sectionLink(filter) {
                                CategoryCard(
                                    category: category,
                                    count: store.count(for: filter),
                                    isSelected: isSelected(filter)
                                )
                            }
                        }

                        sectionLink(.favorites) {
                            DashboardCard(
                                icon: VaultFilter.favorites.icon,
                                title: "Favorites",
                                count: store.count(for: .favorites),
                                color: VaultFilter.favorites.color,
                                isSelected: isSelected(.favorites)
                            )
                        }
                    }
                }

                personalFoldersSection
                sharedGroupsSection
                hiddenItemsSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .refreshable { await store.syncFromPullToRefresh() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if style == .sidebar {
                VStack(spacing: 0) {
                    Divider()
                    sidebarProfileFooter
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .background(.bar)
            }
        }
    }

    private var personalFoldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { personalFoldersExpanded.toggle() }
                } label: {
                    HStack {
                        Text(L10n.format("Personal Folders (%lld)", store.folders.count + 1))
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(personalFoldersExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format(
                    "Personal Folders, %lld, %@",
                    store.folders.count + 1,
                    L10n.string(personalFoldersExpanded ? "expanded" : "collapsed")
                ))
                .accessibilityHint(L10n.format(
                    "Double tap to %@",
                    L10n.string(personalFoldersExpanded ? "collapse" : "expand")
                ))
            }

            if personalFoldersExpanded {
                VStack(spacing: 0) {
                    sectionLink(.unfoldered) {
                        FolderRow(
                            icon: VaultFilter.unfoldered.icon,
                            name: "Unfoldered",
                            count: store.count(for: .unfoldered),
                            color: VaultFilter.unfoldered.color,
                            isSelected: isSelected(.unfoldered)
                        )
                    }

                    if !store.folders.isEmpty {
                        Divider().padding(.leading, 52)
                    }

                    ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                        let filter = VaultFilter.folder(folder.name)
                        sectionLink(filter) {
                            FolderRow(
                                icon: folder.icon,
                                name: folder.name,
                                count: store.count(for: filter),
                                isSelected: isSelected(filter)
                            )
                        }
                        .contextMenu { folderActions(for: folder) }

                        if index < store.folders.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var sharedGroupsSection: some View {
        let shared = store.sharedFilters

        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                collapsibleHeader("Shared Groups", isExpanded: $sharedVaultsExpanded)

                if sharedVaultsExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(shared.enumerated()), id: \.element.id) { index, filter in
                            sectionLink(filter) {
                                FolderRow(
                                    icon: icon(for: filter),
                                    name: store.title(for: filter),
                                    count: store.count(for: filter),
                                    color: filter.color,
                                    isSelected: isSelected(filter)
                                )
                            }

                            if index < shared.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.opacity)
                }
            }
        }
    }

    private var hiddenItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            collapsibleHeader(
                L10n.format("Hidden Items (%lld)", VaultFilter.hiddenCategories.count),
                isExpanded: $hiddenItemsExpanded
            )

            if hiddenItemsExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(VaultFilter.hiddenCategories.enumerated()), id: \.element.id) { index, category in
                        let filter = VaultFilter.category(category)
                        sectionLink(filter) {
                            FolderRow(
                                icon: filter.icon,
                                name: category.localizedTitle,
                                count: store.count(for: filter),
                                color: filter.color,
                                isSelected: isSelected(filter)
                            )
                        }

                        if index < VaultFilter.hiddenCategories.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private var sidebarProfileFooter: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(email: store.settings.email)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Account")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(store.settings.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account and settings")
        .matchedTransitionSource(id: HomeTransition.settings, in: transitions)
    }

    private func collapsibleHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format(
            "%@, %@",
            L10n.string(title),
            L10n.string(isExpanded.wrappedValue ? "expanded" : "collapsed")
        ))
        .accessibilityHint(L10n.format(
            "Double tap to %@",
            L10n.string(isExpanded.wrappedValue ? "collapse" : "expand")
        ))
    }

    // MARK: Activation

    /// A section opens by pushing on iPhone and by moving the split view's
    /// selection on iPad.
    @ViewBuilder
    private func sectionLink<Content: View>(
        _ filter: VaultFilter,
        @ViewBuilder label: () -> Content
    ) -> some View {
        switch style {
        case .dashboard:
            NavigationLink(value: filter) { label() }
                .buttonStyle(.plain)
        case .sidebar:
            Button {
                if store.selectedFilter != filter { store.selectedItemID = nil }
                store.selectedFilter = filter
            } label: {
                label().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func isSelected(_ filter: VaultFilter) -> Bool {
        style == .sidebar && store.selectedFilter == filter
    }

    private func icon(for filter: VaultFilter) -> String {
        if case let .collection(identifier) = filter,
           store.collection(withID: identifier)?.isReadOnly == true {
            return "folder.badge.minus"
        }
        return filter.icon
    }

    @ViewBuilder
    private var searchResultsList: some View {
        let results = store.search(trimmedQuery)

        if results.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Results",
                message: L10n.format("No vault items match “%@”.", trimmedQuery)
            )
        } else {
            List(results) { item in
                NavigationLink(value: item.id) {
                    VaultItemRow(item: item)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func folderActions(for folder: VaultFolder) -> some View {
        Button {
            renameFolderName = folder.name
            folderPendingRename = folder
        } label: {
            Label("Rename Folder", systemImage: "pencil")
        }
        Button(role: .destructive) {
            folderPendingDeletion = folder
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if style == .dashboard {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    ProfileAvatarView(email: store.settings.email)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Account and settings")
                .matchedTransitionSource(id: HomeTransition.settings, in: transitions)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingGenerator = true } label: {
                    Label("Generator", systemImage: "wand.and.sparkles")
                }
                Button { showingSend = true } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Tools")
            .matchedTransitionSource(id: HomeTransition.tools, in: transitions)
        }

        // The sidebar keeps only New Folder up top — search and add belong to
        // the list column beside it.
        if style == .sidebar {
            ToolbarItem(placement: .topBarTrailing) { newFolderButton }
        }

        if style == .dashboard {
            ToolbarItem(placement: .bottomBar) { newFolderButton }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            // No `.searchToolbarBehavior(.minimize)` — the field stays expanded.
            DefaultToolbarItem(kind: .search, placement: .bottomBar)

            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button { showingAddItem = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add vault item")
                .matchedTransitionSource(id: HomeTransition.addItem, in: transitions)
            }
        }
    }

    private var newFolderButton: some View {
        Button { showingAddFolder = true } label: {
            Image(systemName: "folder.badge.plus")
        }
        .accessibilityLabel("Create folder")
    }

    private var renameFolderBinding: Binding<Bool> {
        Binding(
            get: { folderPendingRename != nil },
            set: { if !$0 { folderPendingRename = nil } }
        )
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }
}

private enum HomeTransition {
    static let settings = "home.settings"
    static let tools = "home.tools"
    static let addItem = "home.addItem"
}

/// `.searchable` can't be applied conditionally inline, and the sidebar must
/// not have one — its `DefaultToolbarItem(kind: .search)` would appear too.
private struct SearchableWhenEnabled: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: "Search")
        } else {
            content
        }
    }
}

// MARK: - Dashboard building blocks

private struct CategoryCard: View {
    let category: VaultCategory
    let count: Int
    var isSelected = false

    var body: some View {
        DashboardCard(
            icon: category.icon,
            title: category.localizedTitle,
            count: count,
            color: category.color,
            isSelected: isSelected
        )
    }
}

private struct DashboardCard: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? color : Color.white)
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(color.gradient),
                        in: Circle()
                    )
                    .accessibilityHidden(true)
                Spacer()
                Text(count, format: .number)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        .background(
            isSelected ? color : Color.vaultCard,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct FolderRow: View {
    let icon: String
    let name: String
    let count: Int
    var color: Color = .vaultBlue
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isSelected ? Color.white : color)
                .frame(width: 30)
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Profile avatar

struct ProfileAvatarView: View {
    let email: String

    private var initials: String {
        let handle = email.split(separator: "@").first.map(String.init) ?? ""
        let parts = handle
            .split(whereSeparator: { ".-_+".contains($0) })
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        return parts.joined().uppercased()
    }

    var body: some View {
        Group {
            if initials.isEmpty {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.vaultBlue)
            } else {
                Text(initials)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.vaultBlue.gradient, in: Circle())
            }
        }
    }
}
