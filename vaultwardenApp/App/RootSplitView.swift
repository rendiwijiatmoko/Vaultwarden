import SwiftUI

/// The adaptive shell for the whole authenticated app.
///
/// Compact width shows the home screen as the root of a plain `NavigationStack`.
/// Regular width (iPad and the Mac) uses a `NavigationSplitView` with a native
/// sidebar, a list column and a detail column, opening on All as Passwords does.
struct RootSplitView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var quickActions: HomeQuickActionRouter
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    #if os(iOS)
    // Start iPad with the item list and detail visible. The sidebar can still
    // be revealed with the system's split-view button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    #else
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
    @State private var path = NavigationPath()
    @State private var compactSearchText = ""
    @State private var regularSearchText = ""
    @State private var regularBulkSelection = Set<UUID>()
    @State private var isRegularBulkSelecting = false
    @State private var showingQuickActionPassword = false
    @State private var showingQuickActionGenerator = false
    @FocusState private var compactSearchFocused: Bool
    @FocusState private var regularSearchFocused: Bool

    var body: some View {
        Group {
            if isCompact {
                compactStack
            } else {
                regularSplit
            }
        }
        .task { selectDefaultSectionIfNeeded() }
        .task(id: quickActions.pendingAction) { handlePendingQuickActionIfPossible() }
        .onChange(of: store.isLocked) { _, isLocked in
            if isLocked {
                showingQuickActionPassword = false
                showingQuickActionGenerator = false
            }
            handlePendingQuickActionIfPossible()
        }
        .onChange(of: isCompact) { _, newValue in
            // A window resize or rotation swaps containers entirely. Carry the
            // user's place across instead of dumping them back at the root.
            if newValue {
                restoreCompactPath()
            } else {
                selectDefaultSectionIfNeeded()
                #if os(iOS)
                columnVisibility = .doubleColumn
                preferredCompactColumn = .content
                #endif
            }
        }
        #if os(iOS)
        .onGeometryChange(for: Bool.self, of: { $0.size.width >= 700 }) { wasWide, isWide in
            // A three-column split can collapse without changing size class.
            // Prefer the list while narrow, then restore both columns when
            // the window has room again.
            if wasWide && !isWide {
                preferredCompactColumn = .content
            } else if !wasWide && isWide && !isCompact {
                columnVisibility = .doubleColumn
                preferredCompactColumn = .content
            }
        }
        #endif
        .sheet(isPresented: $showingQuickActionPassword) {
            AddEditVaultItemView(prefilledType: .login)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingQuickActionGenerator) {
            GeneratorView()
                .environmentObject(store)
        }
    }

    private var compactStack: some View {
        NavigationStack(path: $path) {
            VaultHomeView(style: .dashboard, searchText: $compactSearchText)
                .searchable(text: $compactSearchText, prompt: "Search")
                .searchFocused($compactSearchFocused)
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
        path = restored
    }

    private var regularSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            VaultHomeView(style: .sidebar, searchText: $regularSearchText)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                #else
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
                #endif
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
                    #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 460)
                    #else
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
                    #endif
            } else {
                VaultColumnPlaceholder(icon: "lock.rectangle.stack.fill", title: L10n.string("No Section Selected"))
            }
        } detail: {
            regularDetail
                // Search belongs to the detail column so it remains at the far
                // right of the split toolbar. A selected item's Edit action is
                // then placed immediately to its left by the system.
                .searchable(
                    text: $regularSearchText,
                    placement: .toolbar,
                    prompt: Text("Search")
                )
                .searchFocused($regularSearchFocused)
                #if os(macOS)
                .frame(minWidth: 340)
                .background(Color(nsColor: .textBackgroundColor))
                .toolbar {
                    // Keep the content-column controls in their own column
                    // even while the detail has no selected item or actions.
                    if store.selectedItemID == nil {
                        ToolbarSpacer(.flexible, placement: .automatic)
                    }
                }
                #endif
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.selectedFilter) { _, _ in
            store.selectedItemID = nil
            regularSearchText = ""
            updateRegularSelection([], false)
        }
    }

    @ViewBuilder
    private var regularDetail: some View {
        if isRegularBulkSelecting {
            let count = regularBulkSelection.count
            VaultColumnPlaceholder(
                icon: "checkmark.circle",
                title: count == 1 ? L10n.string("1 Item Selected") : L10n.format("%lld Items Selected", count)
            )
        } else if let itemID = store.selectedItemID {
            // Without an explicit identity the reveal toggles stay flipped when
            // the selection moves to another item.
            VaultItemDetailView(itemID: itemID)
                .id(itemID)
        } else {
            VaultColumnPlaceholder(
                icon: store.selectedFilter?.icon ?? "key.fill",
                title: L10n.string("No Item Selected")
            )
        }
    }

    private func updateRegularSelection(_ selection: Set<UUID>, _ isEditing: Bool) {
        regularBulkSelection = selection
        isRegularBulkSelecting = isEditing

        guard isEditing else { return }
        store.selectedItemID = selection.count == 1 ? selection.first : nil
    }

    /// iPad and the Mac open on All. Compact width deliberately stays `nil` so
    /// the home screen is the landing screen.
    private func selectDefaultSectionIfNeeded() {
        guard !isCompact, store.selectedFilter == nil else { return }
        store.selectedFilter = .defaultSelection
    }

    private func handlePendingQuickActionIfPossible() {
        guard !store.isLocked, let action = quickActions.pendingAction else { return }

        switch action {
        case .newPassword:
            showingQuickActionPassword = true
        case let .search(query):
            store.selectedItemID = nil
            if isCompact {
                store.selectedFilter = nil
                path = NavigationPath()
                compactSearchText = query
                focusSearchAfterNavigationChange(compact: true)
            } else {
                selectDefaultSectionIfNeeded()
                regularSearchText = query
                focusSearchAfterNavigationChange(compact: false)
            }
        case .verificationCodes:
            let filter = VaultFilter.category(.codes)
            store.selectedItemID = nil
            store.selectedFilter = filter
            if isCompact {
                var destination = NavigationPath()
                destination.append(filter)
                path = destination
            }
        case .generator:
            showingQuickActionGenerator = true
        }

        quickActions.consume(action)
    }

    private func focusSearchAfterNavigationChange(compact: Bool) {
        Task { @MainActor in
            await Task.yield()
            if compact {
                compactSearchFocused = true
            } else {
                regularSearchFocused = true
            }
        }
    }
}

private struct VaultColumnPlaceholder: View {
    let icon: String
    let title: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color.vaultBackground)
            #endif
    }
}

// MARK: - Vault home

enum VaultHomeStyle {
    /// iPhone: root of a navigation stack. Taps push; the bottom bar carries
    /// new folder, search and add.
    case dashboard
    /// iPad and the Mac: the split view's sidebar column, a native source list
    /// whose selection drives the list column.
    case sidebar
}

/// The vault's home: smart sections, item types, folders and shared groups.
/// A grid of tiles on iPhone, as in Passwords and Reminders; a source list in a sidebar.
struct VaultHomeView: View {
    /// Passed in rather than derived from `horizontalSizeClass`: content hosted
    /// in a split view column does not reliably report the window's size class,
    /// and guessing wrong here would render links that have no destination.
    let style: VaultHomeStyle
    @Binding var searchText: String

    @EnvironmentObject private var store: AppStore

    @State private var showingSettings = false
    @State private var showingGenerator = false
    @State private var showingSend = false
    @State private var showingAddItem = false
    @State private var showingAddFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingRename: VaultFolder?
    @State private var renameFolderName = ""
    @State private var folderPendingDeletion: VaultFolder?

    @AppStorage("vault.home.foldersExpanded") private var foldersExpanded = true
    @AppStorage("vault.home.sharedExpanded") private var sharedExpanded = true

    @Namespace private var transitions

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search only lives on the iPhone home screen; the split view's list column has its own.
    private var isSearching: Bool { style == .dashboard && !trimmedQuery.isEmpty }

    /// SSH keys and the archive appear once there is something in them.
    private var visibleTypeSections: [VaultFilter] {
        VaultFilter.typeSections.filter { filter in
            filter != .category(.sshKeys) || store.count(for: filter) > 0
        }
    }

    private var showsArchive: Bool { store.count(for: .category(.archived)) > 0 }

    var body: some View {
        Group {
            if isSearching {
                VaultSearchResults(query: trimmedQuery)
            } else if style == .sidebar {
                sidebar
            } else {
                dashboard
            }
        }
        .navigationTitle(style == .sidebar ? "" : L10n.string("Vault"))
        .vaultNavigationTitleDisplayMode(style == .sidebar ? .inline : .large)
        #if os(iOS)
        .toolbar { toolbarContent }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Generator", systemImage: "wand.and.sparkles") { showingGenerator = true }
                    Button("Send", systemImage: "paperplane") { showingSend = true }
                    Divider()
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await store.sync() } }
                        .disabled(store.isSyncing)
                } label: {
                    Label("Tools", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("Tools")
            }
        }
        #endif
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(store)
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: HomeTransition.settings, in: transitions))
                #endif
        }
        .sheet(isPresented: $showingGenerator) {
            GeneratorView()
                .environmentObject(store)
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: HomeTransition.tools, in: transitions))
                #endif
        }
        .sheet(isPresented: $showingSend) {
            SendView()
                .environmentObject(store)
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: HomeTransition.tools, in: transitions))
                #endif
        }
        .sheet(isPresented: $showingAddItem) {
            AddEditVaultItemView()
                .environmentObject(store)
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: HomeTransition.addItem, in: transitions))
                #endif
        }
        .alert("New Folder", isPresented: $showingAddFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolderName = ""
                guard !name.isEmpty else { return }
                Task { _ = await store.addFolder(named: name) }
            }
        }
        .alert("Rename Folder", isPresented: renameFolderBinding) {
            TextField("Name", text: $renameFolderName)
            Button("Cancel", role: .cancel) { folderPendingRename = nil }
            Button("Rename") {
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
        }
        .confirmationDialog(
            folderPendingDeletion.map { L10n.format("Delete “%@”?", $0.name) } ?? L10n.string("Delete Folder?"),
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
            Text("Its items move to No Folder.")
        }
    }

    // MARK: Sidebar (iPad and Mac)

    private var sidebar: some View {
        List(selection: $store.selectedFilter) {
            Section {
                ForEach(VaultFilter.smartSections) { filter in
                    sidebarRow(filter)
                }
            }

            Section("Categories") {
                ForEach(visibleTypeSections) { filter in
                    sidebarRow(filter)
                }
                if showsArchive {
                    sidebarRow(.category(.archived))
                }
            }

            Section {
                sidebarRow(.unfoldered)
                ForEach(store.sortedFolders) { folder in
                    sidebarRow(.folder(folder.name), icon: folder.icon)
                        .contextMenu { folderActions(for: folder) }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    newFolderButton
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            ForEach(store.sharedCollectionGroups) { group in
                Section(group.name) {
                    ForEach(group.filters) { filter in
                        sidebarRow(filter, icon: icon(for: filter))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                sidebarProfileFooter
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(.bar)
        }
        #endif
    }

    private func sidebarRow(_ filter: VaultFilter, icon: String? = nil) -> some View {
        VaultSidebarLabel(
            title: filter.builtInTitle ?? store.title(for: filter),
            icon: icon ?? filter.icon,
            color: filter.color
        )
        // Only open security issues earn a badge; other counts are a click away.
        .badge(filter == .category(.security) ? store.count(for: filter) : 0)
        .tag(Optional(filter))
    }

    // MARK: Dashboard (iPhone)

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    VaultSyncStatusText()
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(VaultFilter.smartSections) { filter in
                            NavigationLink(value: filter) {
                                VaultCategoryTile(
                                    title: filter.builtInTitle ?? store.title(for: filter),
                                    icon: filter.icon,
                                    color: filter.color,
                                    count: store.count(for: filter)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Categories")
                        .font(.title3.bold())
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                    HomeRowCard {
                        ForEach(visibleTypeSections) { filter in
                            homeRow(filter)
                        }
                        if showsArchive {
                            homeRow(.category(.archived))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    collapsibleHeader(L10n.string("Folders"), isExpanded: $foldersExpanded)
                    if foldersExpanded {
                        HomeRowCard {
                            homeRow(.unfoldered)
                            ForEach(store.sortedFolders) { folder in
                                homeRow(.folder(folder.name), icon: folder.icon)
                                    .contextMenu { folderActions(for: folder) }
                            }
                        }
                        .transition(.opacity)
                    }
                }

                if !store.sharedFilters.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        collapsibleHeader(L10n.string("Shared Groups"), isExpanded: $sharedExpanded)
                        if sharedExpanded {
                            ForEach(store.sharedCollectionGroups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                    HomeRowCard {
                                        ForEach(group.filters) { filter in
                                            homeRow(filter, icon: icon(for: filter))
                                        }
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Color.vaultBackground)
        .refreshable { await store.syncFromPullToRefresh() }
    }

    private func homeRow(_ filter: VaultFilter, icon: String? = nil) -> some View {
        NavigationLink(value: filter) {
            HomeRow(
                icon: icon ?? filter.icon,
                name: filter.builtInTitle ?? store.title(for: filter),
                count: store.count(for: filter),
                color: filter.color
            )
        }
        .buttonStyle(.plain)
    }

    private func collapsibleHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(VaultMotion.panel) { isExpanded.wrappedValue.toggle() }
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
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded.wrappedValue ? L10n.string("Expanded") : L10n.string("Collapsed"))
    }

    private var sidebarProfileFooter: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(email: store.settings.email)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account")
                        .font(.headline)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account and Settings")
        .matchedTransitionSource(id: HomeTransition.settings, in: transitions)
    }

    private func icon(for filter: VaultFilter) -> String {
        if case let .collection(identifier) = filter,
           store.collection(withID: identifier)?.isReadOnly == true {
            return "lock.fill"
        }
        return filter.icon
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

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if style == .dashboard {
            ToolbarItem(placement: .vaultLeading) {
                Button { showingSettings = true } label: {
                    ProfileAvatarView(email: store.settings.email)
                }
                .buttonStyle(.plain)
                .tint(nil)
                .accessibilityLabel("Account and Settings")
                .matchedTransitionSource(id: HomeTransition.settings, in: transitions)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .vaultTrailing) {
            Menu {
                Button { showingGenerator = true } label: {
                    Label("Generator", systemImage: "wand.and.sparkles")
                }
                Button { showingSend = true } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
            } label: {
                Label("Tools", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .tint(nil)
            .matchedTransitionSource(id: HomeTransition.tools, in: transitions)
        }

        if style == .dashboard {
            ToolbarItem(placement: .vaultBottomBar) { newFolderButton }

            ToolbarSpacer(.flexible, placement: .vaultBottomBar)

            DefaultToolbarItem(kind: .search, placement: .vaultBottomBar)

            ToolbarSpacer(.flexible, placement: .vaultBottomBar)

            ToolbarItem(placement: .vaultBottomBar) {
                Button("New Item", systemImage: "plus") { showingAddItem = true }
                    .labelStyle(.iconOnly)
                    .tint(nil)
                    .matchedTransitionSource(id: HomeTransition.addItem, in: transitions)
            }
        }
    }
    #endif

    private var newFolderButton: some View {
        Button("New Folder", systemImage: "folder.badge.plus") { showingAddFolder = true }
            .labelStyle(.iconOnly)
            .tint(nil)
            .help("New Folder")
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

// MARK: - Home building blocks

/// A rounded card of rows on the iPhone home screen, with inset separators.
private struct HomeRowCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview
                    if index < subviews.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .background(Color.vaultCard, in: .rect(cornerRadius: 20))
    }
}

private struct HomeRow: View {
    let icon: String
    let name: String
    let count: Int
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(name)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer()
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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
        if initials.isEmpty {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        } else {
            Text(initials)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: .circle)
        }
    }
}
