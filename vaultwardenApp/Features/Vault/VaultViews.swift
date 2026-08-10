import SwiftUI
import UIKit

struct VaultView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var showingAddItem = false
    @State private var showingAddFolder = false
    @State private var folderName = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    VaultDashboard(showingAddFolder: $showingAddFolder)
                } else {
                    VaultItemListContent(items: store.search(searchText), emptyMessage: "No vault items match “\(searchText)”.")
                }
            }
            .background(Color.vaultBackground)
            .navigationTitle("Vault")
            .toolbarTitleDisplayMode(.inlineLarge)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your vault")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button { store.lock(requestAutomaticUnlock: false) } label: {
                            Label("Lock Now", systemImage: "lock.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }

                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddItem = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add vault item")
                }
            }
            .sheet(isPresented: $showingAddItem) {
                AddEditVaultItemView()
            }
            .alert("New Folder", isPresented: $showingAddFolder) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) { folderName = "" }
                Button("Create") {
                    let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    folderName = ""
                    Task { _ = await store.addFolder(named: name) }
                }
            } message: {
                Text("Folders organize your personal vault. They are not shared with organization members.")
            }
        }
    }

}

private struct VaultDashboard: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingAddFolder: Bool
    @State private var favoritesExpanded = true
    @State private var personalFoldersExpanded = true
    @State private var sharedVaultsExpanded = true
    @State private var hiddenItemsExpanded = false
    @State private var folderToRename: VaultFolder?
    @State private var folderToDelete: VaultFolder?
    @State private var renameFolderName = ""
    @State private var showingRenameFolder = false
    @State private var showingDeleteFolder = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var favoriteItems: [VaultItem] {
        store.activeItems.filter(\.isFavorite)
    }

    private var dashboardCategories: [VaultCategory] {
        VaultCategory.allCases.filter { $0 != .archived && $0 != .deleted }
    }

    private var hiddenCategories: [VaultCategory] {
        [.archived, .deleted]
    }

    private var personalFolderCount: Int {
        store.folders.count + 1
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    VaultSyncStatusText()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(dashboardCategories) { category in
                            NavigationLink {
                                VaultCollectionView(title: category.rawValue, items: store.items(in: category), category: category)
                            } label: {
                                CategoryCard(category: category, count: store.count(for: category))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !favoriteItems.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        collapsibleHeader("Favorites", isExpanded: $favoritesExpanded)

                        if favoritesExpanded {
                            ForEach(favoriteItems.prefix(5)) { item in
                                NavigationLink {
                                    VaultItemDetailView(itemID: item.id)
                                } label: {
                                    VaultItemRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            if favoriteItems.count > 5 {
                                NavigationLink {
                                    VaultCollectionView(title: "Favorites", items: favoriteItems)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("See More")
                                            .font(.subheadline.weight(.semibold))
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold())
                                    }
                                    .foregroundStyle(Color.vaultBlue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.snappy) {
                                personalFoldersExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Personal Folders (\(personalFolderCount))")
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
                        .accessibilityLabel("Personal Folders, \(personalFolderCount), \(personalFoldersExpanded ? "expanded" : "collapsed")")
                        .accessibilityHint("Double tap to \(personalFoldersExpanded ? "collapse" : "expand")")

                        Button { showingAddFolder = true } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .accessibilityLabel("Create folder")
                    }

                    if personalFoldersExpanded {
                        VStack(spacing: 0) {
                            NavigationLink {
                                VaultCollectionView(title: "Unfolder", items: store.unfolderedItems)
                            } label: {
                                FolderRow(
                                    icon: "questionmark.folder.fill",
                                    name: "Unfolder",
                                    count: store.unfolderedItems.count,
                                    color: .secondary
                                )
                            }
                            .buttonStyle(.plain)

                            if !store.folders.isEmpty {
                                Divider().padding(.leading, 52)
                            }

                            ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                                NavigationLink {
                                    VaultCollectionView(title: folder.name, items: store.items(inFolder: folder.name))
                                } label: {
                                    FolderRow(icon: folder.icon, name: folder.name, count: store.items(inFolder: folder.name).count)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        folderToRename = folder
                                        renameFolderName = folder.name
                                        showingRenameFolder = true
                                    } label: {
                                        Label("Rename Folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        folderToDelete = folder
                                        showingDeleteFolder = true
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                                if index < store.folders.count - 1 { Divider().padding(.leading, 52) }
                            }
                        }
                        .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if !store.organizations.isEmpty || !store.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        collapsibleHeader("Shared Vaults", isExpanded: $sharedVaultsExpanded)

                        if sharedVaultsExpanded {
                            VStack(spacing: 0) {
                                if store.collections.isEmpty {
                                    ForEach(Array(store.organizations.enumerated()), id: \.element) { index, organization in
                                        NavigationLink {
                                            VaultCollectionView(title: organization, items: store.items(inOrganization: organization))
                                        } label: {
                                            FolderRow(icon: "person.2.fill", name: organization, count: store.items(inOrganization: organization).count, color: .vaultGreen)
                                        }
                                        .buttonStyle(.plain)
                                        if index < store.organizations.count - 1 { Divider().padding(.leading, 52) }
                                    }
                                } else {
                                    ForEach(Array(store.collections.enumerated()), id: \.element.id) { index, collection in
                                        NavigationLink {
                                            VaultCollectionView(title: collection.name, items: store.items(inCollection: collection))
                                        } label: {
                                            FolderRow(
                                                icon: collection.isReadOnly ? "folder.badge.minus" : "person.2.fill",
                                                name: collection.name,
                                                count: store.items(inCollection: collection).count,
                                                color: .vaultGreen
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        if index < store.collections.count - 1 { Divider().padding(.leading, 52) }
                                    }
                                }
                            }
                            .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    collapsibleHeader("Hidden Items (\(hiddenCategories.count))", isExpanded: $hiddenItemsExpanded)

                    if hiddenItemsExpanded {
                        VStack(spacing: 0) {
                            ForEach(Array(hiddenCategories.enumerated()), id: \.element.id) { index, category in
                                NavigationLink {
                                    VaultCollectionView(
                                        title: category.rawValue,
                                        items: store.items(in: category),
                                        category: category
                                    )
                                } label: {
                                    FolderRow(
                                        icon: category.icon,
                                        name: category.rawValue,
                                        count: store.count(for: category),
                                        color: category.color
                                    )
                                }
                                .buttonStyle(.plain)

                                if index < hiddenCategories.count - 1 {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                        .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .refreshable { await store.syncFromPullToRefresh() }
        .alert("Rename Folder", isPresented: $showingRenameFolder) {
            TextField("Folder name", text: $renameFolderName)
            Button("Cancel", role: .cancel) { folderToRename = nil }
            Button("Save") {
                guard let folder = folderToRename else { return }
                let name = renameFolderName
                folderToRename = nil
                Task { _ = await store.renameFolder(folder, to: name) }
            }
        } message: {
            Text("Items in this folder will keep their assignment.")
        }
        .confirmationDialog(
            "Delete \(folderToDelete?.name ?? "folder")?",
            isPresented: $showingDeleteFolder,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = folderToDelete else { return }
                folderToDelete = nil
                Task { await store.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Vault items are kept and moved to Unfolder.")
        }
    }

    private func collapsibleHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) {
                isExpanded.wrappedValue.toggle()
            }
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
        .accessibilityLabel("\(title), \(isExpanded.wrappedValue ? "expanded" : "collapsed")")
        .accessibilityHint("Double tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")
    }

}

private struct VaultSyncStatusText: View {
    @EnvironmentObject private var store: AppStore

    private var appearance: (text: String, color: Color) {
        if store.isSyncing {
            return ("Syncing encrypted vault…", .vaultBlue)
        }
        if store.pendingMutationCount > 0 {
            let suffix = store.pendingMutationCount == 1 ? "" : "s"
            return (
                "\(store.pendingMutationCount) encrypted change\(suffix) queued",
                .vaultOrange
            )
        }
        if store.lastSyncError != nil {
            return ("Sync failed · Pull to retry", .vaultRed)
        }
        if store.lastSyncUsedOfflineCache {
            return ("Showing offline vault · Pull to retry", .vaultYellow)
        }
        return (
            "Synced \(store.lastSync.formatted(.relative(presentation: .named)))",
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

private struct CategoryCard: View {
    let category: VaultCategory
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VaultIcon(systemName: category.icon, color: category.color, size: 34)
                Spacer()
                Text(count, format: .number)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text(category.rawValue)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct FolderRow: View {
    let icon: String
    let name: String
    let count: Int
    var color: Color = .vaultBlue

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30)
            Text(name)
                .font(.body.weight(.medium))
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

struct VaultCollectionView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let items: [VaultItem]
    var category: VaultCategory?
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var pendingDeletion: [VaultItem] = []
    @State private var pendingArchive: [VaultItem] = []
    @State private var showingDeleteConfirmation = false
    @State private var showingArchiveConfirmation = false

    private var liveItems: [VaultItem] {
        if let category { return store.items(in: category) }
        let sourceIDs = Set(items.map(\.id))
        return store.items.filter {
            sourceIDs.contains($0.id) && !$0.isDeleted && !$0.isArchived
        }
    }

    private var filteredItems: [VaultItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return liveItems }
        return liveItems.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || $0.uri.localizedCaseInsensitiveContains(query)
                || $0.type.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedItems: [VaultItem] {
        store.items.filter { selection.contains($0.id) }
    }

    private var visibleItemIDs: Set<UUID> {
        Set(filteredItems.map(\.id))
    }

    private var hasSelectedAllVisibleItems: Bool {
        !visibleItemIDs.isEmpty && visibleItemIDs.isSubset(of: selection)
    }

    var body: some View {
        Group {
            if filteredItems.isEmpty, category != .security {
                EmptyStateView(
                    icon: searchText.isEmpty ? (category?.icon ?? "folder") : "magnifyingglass",
                    title: searchText.isEmpty ? "Nothing here" : "No Results",
                    message: searchText.isEmpty
                        ? "Items in this section will appear here."
                        : "No vault items match “\(searchText)”."
                )
            } else {
                List(selection: editMode.isEditing ? $selection : nil) {
                    if category == .security, !editMode.isEditing {
                        Section {
                            SecurityInformationCard()
                        }
                    }

                    if filteredItems.isEmpty {
                        Section {
                            EmptyStateView(
                                icon: searchText.isEmpty ? "checkmark.shield.fill" : "magnifyingglass",
                                title: searchText.isEmpty ? "No Recommendations" : "No Results",
                                message: searchText.isEmpty
                                    ? "No security issues were found in your active vault."
                                    : "No security recommendations match “\(searchText)”."
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            ForEach(filteredItems) { item in
                                row(for: item)
                                    .tag(item.id)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        deleteButton(for: item)
                                        archiveButton(for: item)
                                    }
                                    .contextMenu {
                                        archiveButton(for: item)
                                        deleteButton(for: item)
                                    }
                                    .confirmationDialog(
                                        deleteConfirmationTitle,
                                        isPresented: rowDeleteConfirmationBinding(for: item),
                                        titleVisibility: .visible,
                                        actions: deleteConfirmationActions,
                                        message: deleteConfirmationMessage
                                    )
                                    .confirmationDialog(
                                        archiveConfirmationTitle,
                                        isPresented: rowArchiveConfirmationBinding(for: item),
                                        titleVisibility: .visible,
                                        actions: archiveConfirmationActions,
                                        message: archiveConfirmationMessage
                                    )
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .environment(\.editMode, $editMode)
        .onAppear {
            guard !editMode.isEditing else { return }
            selection.removeAll()
        }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selection.removeAll()
            }
        }
        .navigationTitle(title)
        .modifier(
            OptionalNavigationSubtitle(
                subtitle: category == .security ? "\(liveItems.count) Recommendations" : nil
            )
        )
        .navigationBarTitleDisplayMode(category == .security ? .inline : .large)
        .navigationBarBackButtonHidden(editMode.isEditing)
        .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search \(title.lowercased())"
        )
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(hasSelectedAllVisibleItems ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) { toggleSelectAll() }
                    }
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
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation(.snappy) {
                        if editMode.isEditing {
                            editMode = .inactive
                            selection.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                }
                .disabled(liveItems.isEmpty)
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
    }

    private var sharedCodePeriod: Int {
        liveItems.compactMap(\.totpSecret).first.map(TOTPGenerator.period(secret:)) ?? 30
    }

    @ViewBuilder
    private func row(for item: VaultItem) -> some View {
        if editMode.isEditing {
            collectionRowContent(for: item)
        } else if category == .codes, let secret = item.totpSecret {
            TOTPItemRow(item: item, secret: secret)
        } else {
            NavigationLink {
                VaultItemDetailView(itemID: item.id)
            } label: {
                collectionRowContent(for: item)
            }
        }
    }

    @ViewBuilder
    private func collectionRowContent(for item: VaultItem) -> some View {
        if category == .security {
            SecurityRecommendationRow(item: item)
        } else {
            VaultItemRow(item: item)
        }
    }

    @ViewBuilder
    private func archiveButton(for item: VaultItem) -> some View {
        if !item.isDeleted {
            Button {
                pendingArchive = [item]
                showingArchiveConfirmation = true
            } label: {
                Label(item.isArchived ? "Unarchive" : "Archive", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.orange)
        } else {
            Button {
                pendingArchive = [item]
                showingArchiveConfirmation = true
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
    }

    private func deleteButton(for item: VaultItem) -> some View {
        Button(role: .destructive) {
            pendingDeletion = [item]
            showingDeleteConfirmation = true
        } label: {
            Label(item.isDeleted ? "Delete Permanently" : "Move to Deleted", systemImage: "trash")
        }
    }

    private var bulkSecondaryTitle: String {
        if category == .deleted { return "Restore" }
        if category == .archived { return "Unarchive" }
        return "Archive"
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
        pendingDeletion.allSatisfy(\.isDeleted)
            ? "Delete permanently?"
            : "Move to Deleted?"
    }

    private var archiveConfirmationTitle: String {
        let suffix = pendingArchive.count == 1 ? "item" : "selected items"
        if pendingArchive.allSatisfy(\.isDeleted) { return "Restore \(suffix)?" }
        if pendingArchive.allSatisfy(\.isArchived) { return "Unarchive \(suffix)?" }
        return "Archive \(suffix)?"
    }

    @ViewBuilder
    private func deleteConfirmationActions() -> some View {
        Button(
            pendingDeletion.allSatisfy(\.isDeleted) ? "Delete Permanently" : "Move to Deleted",
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
        if pendingArchive.allSatisfy(\.isDeleted) { return "Restore" }
        if pendingArchive.allSatisfy(\.isArchived) { return "Unarchive" }
        return "Archive"
    }

    private func archiveConfirmationMessage() -> some View {
        Text("This action applies to \(pendingArchive.count) selected item\(pendingArchive.count == 1 ? "" : "s").")
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

    private func rowDeleteConfirmationBinding(for item: VaultItem) -> Binding<Bool> {
        Binding(
            get: {
                showingDeleteConfirmation
                    && !editMode.isEditing
                    && pendingDeletion.count == 1
                    && pendingDeletion.first?.id == item.id
            },
            set: { newValue in
                showingDeleteConfirmation = newValue
                if !newValue { pendingDeletion = [] }
            }
        )
    }

    private func rowArchiveConfirmationBinding(for item: VaultItem) -> Binding<Bool> {
        Binding(
            get: {
                showingArchiveConfirmation
                    && !editMode.isEditing
                    && pendingArchive.count == 1
                    && pendingArchive.first?.id == item.id
            },
            set: { newValue in
                showingArchiveConfirmation = newValue
                if !newValue { pendingArchive = [] }
            }
        )
    }

    private func toggleSelectAll() {
        if hasSelectedAllVisibleItems {
            selection.subtract(visibleItemIDs)
        } else {
            selection.formUnion(visibleItemIDs)
        }
    }
}

private struct OptionalNavigationSubtitle: ViewModifier {
    let subtitle: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

private struct SecurityInformationCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Security Recommendations", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(Color.vaultBlue)

            Text("Vaultwarden highlights passwords that may be exposed, weak, reused, or used on unsecured websites so you can update them quickly.")
                .font(.body)
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
                    .lineLimit(1)

                Text(recommendation.text)
                    .font(.subheadline)
                    .foregroundStyle(recommendation.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct VaultItemListContent: View {
    let items: [VaultItem]
    let emptyMessage: String

    var body: some View {
        if items.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "No Results", message: emptyMessage)
        } else {
            List(items) { item in
                NavigationLink {
                    VaultItemDetailView(itemID: item.id)
                } label: {
                    VaultItemRow(item: item)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct VaultItemRow: View {
    @EnvironmentObject private var store: AppStore
    let item: VaultItem

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
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.vaultYellow)
                    }
                }
                Text(item.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                if item.passkeyCount > 0 { Image(systemName: "person.badge.key.fill") }
                if item.totpSecret != nil { Image(systemName: "lock.rotation") }
                if item.organization != nil { Image(systemName: "person.2.fill") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
    let itemID: UUID
    @State private var revealPassword = false
    @State private var revealCardNumber = false
    @State private var revealSecurityCode = false
    @State private var revealIdentityNumber = false
    @State private var showingEdit = false
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false

    private var item: VaultItem? { store.items.first { $0.id == itemID } }

    var body: some View {
        Group {
            if let item {
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
                                Text(item.type.rawValue)
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
                                        Text("\(item.passkeyCount) Passkey\(item.passkeyCount == 1 ? "" : "s") Stored")
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text("Passkeys are a secure way to sign in using Face ID or your device passcode. They provide stronger phishing resistance than traditional passwords.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }

                        if !item.uri.isEmpty {
                            Section("Website") {
                                LabeledContent("URI", value: item.uri)
                                if let url = URL(string: item.uri) {
                                    Link(destination: url) { Label("Open Website", systemImage: "safari") }
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
                                Label(risk.rawValue, systemImage: "exclamationmark.triangle.fill")
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
                                        Task { await store.permanentlyDelete(item) }
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
                            Text("Created \((item.createdAt ?? item.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                            Text("Last edited \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .textCase(nil)
                    }
                }
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !item.isDeleted {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Edit") { showingEdit = true }
                        }
                    }
                }
                .sheet(isPresented: $showingEdit) { AddEditVaultItemView(existingItem: item) }
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
                Task { await store.trash(item) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can restore this item later from Deleted.")
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
                Label("Found \(count.formatted()) times. Change this password as soon as possible.", systemImage: "exclamationmark.triangle.fill")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if canCopy {
                    AnimatedCopyButton(value: value, accessibilityName: title)
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
            SecretFieldRow(title: field.name, value: resolvedValue, revealed: revealed) {
                revealed.toggle()
            }
        case .linked where field.value == "password":
            SecretFieldRow(title: field.name, value: resolvedValue, revealed: revealed) {
                revealed.toggle()
            }
        case .text, .linked:
            DetailValueRow(title: field.name, value: resolvedValue)
        }
    }
}

private struct SecretFieldRow: View {
    let title: String
    let value: String
    let revealed: Bool
    var copyValue: String? = nil
    var toggleReveal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
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
                AnimatedCopyButton(value: copyValue ?? value, accessibilityName: title)
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
            .accessibilityLabel(copied ? "Verification code copied" : "Copy verification code \(code)")
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let code = TOTPGenerator.code(secret: secret, date: context.date) ?? "------"

            HStack(spacing: 12) {
                NavigationLink {
                    VaultItemDetailView(itemID: item.id)
                } label: {
                    HStack(spacing: 12) {
                        VaultItemThumbnail(
                            item: item,
                            showsWebsiteIcon: store.settings.showFavicons,
                            serverURL: store.authenticatedSession?.serverURL
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(item.username.isEmpty ? item.displaySubtitle : item.username)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Text(code.chunked(every: 3))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                            .accessibilityLabel("Code \(code)")
                    }
                }
                .buttonStyle(.plain)

                AnimatedCopyButton(value: code, accessibilityName: "verification code")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
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
        .accessibilityLabel("Code refreshes in \(secondsRemaining) seconds")
    }
}

private struct LabeledFormField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let capitalization: TextInputAutocapitalization?
    let autocorrectionDisabled: Bool

    init(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        keyboardType: UIKeyboardType = .default,
        textContentType: UITextContentType? = nil,
        capitalization: TextInputAutocapitalization? = nil,
        autocorrectionDisabled: Bool = false
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
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

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.body)
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled(autocorrectionDisabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

struct AddEditVaultItemView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private let existingItem: VaultItem?
    private let existingID: UUID?
    @State private var name: String
    @State private var username: String
    @State private var password: String
    @State private var uri: String
    @State private var type: VaultItemType
    @State private var folder: String
    @State private var notes: String
    @State private var isFavorite: Bool
    @State private var totpSecret: String
    @State private var card: CardDetails
    @State private var identity: IdentityDetails
    @State private var customFields: [VaultCustomField]
    @State private var showingGenerator = false
    @State private var isSaving = false

    init(existingItem: VaultItem? = nil, prefilledPassword: String = "") {
        self.existingItem = existingItem
        existingID = existingItem?.id
        _name = State(initialValue: existingItem?.name ?? "")
        _username = State(initialValue: existingItem?.username ?? "")
        _password = State(initialValue: existingItem?.password ?? prefilledPassword)
        _uri = State(initialValue: existingItem?.uri ?? "")
        _type = State(initialValue: existingItem?.type ?? .login)
        _folder = State(initialValue: existingItem?.folder ?? "")
        _notes = State(initialValue: existingItem?.notes ?? "")
        _isFavorite = State(initialValue: existingItem?.isFavorite ?? false)
        _totpSecret = State(initialValue: existingItem?.totpSecret ?? "")
        _card = State(initialValue: existingItem?.card ?? CardDetails())
        _identity = State(initialValue: existingItem?.identity ?? IdentityDetails())
        _customFields = State(initialValue: existingItem?.customFields ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(VaultItemType.allCases) { Text($0.rawValue).tag($0) }
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
                            capitalization: .never,
                            autocorrectionDisabled: true
                        )
                        LabeledFormField("Password", text: $password, placeholder: "Enter password", isSecure: true)
                        Button("Generate Password") { showingGenerator = true }
                    }
                    Section("Website") {
                        LabeledFormField(
                            "Website URI",
                            text: $uri,
                            placeholder: "https://example.com",
                            keyboardType: .URL,
                            capitalization: .never,
                            autocorrectionDisabled: true
                        )
                    }
                    Section("Authenticator") {
                        LabeledFormField(
                            "TOTP Secret",
                            text: $totpSecret,
                            placeholder: "Optional",
                            capitalization: .characters,
                            autocorrectionDisabled: true
                        )
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
                        .frame(minHeight: 100)
                }

                customFieldsEditor
            }
            .navigationTitle(existingID == nil ? "New Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingGenerator) {
                QuickPasswordGeneratorView { generated in
                    password = generated
                    showingGenerator = false
                }
            }
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
                LabeledFormField("Title", text: $identity.title, placeholder: "Mr, Mrs, Dr, etc.")
                LabeledFormField("First Name", text: $identity.firstName, placeholder: "Enter first name", textContentType: .givenName)
                LabeledFormField("Middle Name", text: $identity.middleName, placeholder: "Optional", textContentType: .middleName)
                LabeledFormField("Last Name", text: $identity.lastName, placeholder: "Enter last name", textContentType: .familyName)
                LabeledFormField("Username", text: $identity.username, placeholder: "Enter username", capitalization: .never)
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
                                    Label(type.rawValue, systemImage: type.icon).tag(type)
                                }
                            }
                        } label: {
                            Text(field.type.rawValue)
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

    private func save() async {
        var item = existingItem ?? VaultItem(name: name)
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.username = username
        item.password = password
        item.uri = uri
        item.type = type
        item.folder = folder.isEmpty ? nil : folder
        item.notes = notes
        item.isFavorite = isFavorite
        item.totpSecret = totpSecret.isEmpty ? nil : totpSecret
        item.card = type == .card ? card : nil
        item.identity = type == .identity ? identity : nil
        item.customFields = customFields.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let existingID { item.id = existingID }
        isSaving = true
        defer { isSaving = false }
        if await store.save(item) {
            dismiss()
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
