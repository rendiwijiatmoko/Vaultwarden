import Combine
import SwiftUI

/// A question asked only when something would be lost.
struct VaultItemConfirmation: Identifiable {
    enum Kind {
        case trash
        case deletePermanently
    }

    let id = UUID()
    let kind: Kind
    let itemIDs: [UUID]
    let title: String
    let actionTitle: String
    let message: String

    static func make(_ kind: Kind, items: [VaultItem]) -> VaultItemConfirmation? {
        guard let first = items.first else { return nil }
        let single = items.count == 1
        switch kind {
        case .trash:
            return VaultItemConfirmation(
                kind: kind,
                itemIDs: items.map(\.id),
                title: single
                    ? L10n.format("Delete “%@”?", first.name)
                    : L10n.format("Delete %lld Items?", items.count),
                actionTitle: L10n.string("Delete"),
                message: L10n.string(single ? "You can restore it from Deleted." : "You can restore them from Deleted.")
            )
        case .deletePermanently:
            return VaultItemConfirmation(
                kind: kind,
                itemIDs: items.map(\.id),
                title: single
                    ? L10n.format("Delete “%@” Permanently?", first.name)
                    : L10n.format("Delete %lld Items Permanently?", items.count),
                actionTitle: L10n.string("Delete Permanently"),
                message: L10n.string("This can’t be undone.")
            )
        }
    }
}

/// The actions every item surface shares: context menus, swipe actions and the
/// Mac's keyboard commands. One model, so every door says and does the same thing.
final class VaultItemActionModel: ObservableObject {
    enum CopyField {
        case username, password, code

        var noticeTitle: String {
            switch self {
            case .username: L10n.string("User Name Copied")
            case .password: L10n.string("Password Copied")
            case .code: L10n.string("Code Copied")
            }
        }
    }

    @Published var confirmation: VaultItemConfirmation?
    @Published private(set) var notice: String?
    // Haptics follow these counters, which only a person's action moves.
    @Published private(set) var copyCount = 0
    @Published private(set) var favoriteCount = 0
    @Published private(set) var deleteCount = 0
    private var noticeTask: Task<Void, Never>?

    func copy(_ field: CopyField, from item: VaultItem, store: AppStore) {
        Task {
            if field != .username {
                guard await VaultSensitiveAccess.authorize(store) else { return }
            }
            // Re-read after authenticating: the item, the lock or its permissions may have changed.
            guard let current = store.items.first(where: { $0.id == item.id }),
                  let value = Self.value(field, of: current, store: store) else { return }
            Clipboard.copy(value)
            copyCount += 1
            announce(field.noticeTitle)
        }
    }

    func toggleFavorite(_ item: VaultItem, store: AppStore) {
        favoriteCount += 1
        Task { await store.toggleFavorite(item) }
    }

    func move(_ item: VaultItem, toFolder folder: String?, store: AppStore) {
        let target = folder?.isEmpty == true ? nil : folder
        guard item.folder != target else { return }
        var updated = item
        updated.folder = target
        Task { await store.save(updated) }
    }

    /// Items in Deleted can be restored, so moving there doesn't ask first.
    func trash(_ items: [VaultItem], store: AppStore) {
        guard !items.isEmpty else { return }
        deleteCount += 1
        Task {
            for item in items {
                if await store.trash(item), store.selectedItemID == item.id {
                    store.selectedItemID = nil
                }
            }
        }
    }

    func archive(_ items: [VaultItem], store: AppStore) {
        Task {
            for item in items {
                if item.isArchived { await store.unarchive(item) } else { await store.archive(item) }
            }
        }
    }

    func restore(_ items: [VaultItem], store: AppStore) {
        Task {
            for item in items { await store.restore(item) }
        }
    }

    func requestPermanentDeletion(_ items: [VaultItem]) {
        confirmation = .make(.deletePermanently, items: items)
    }

    func requestTrash(_ items: [VaultItem]) {
        confirmation = .make(.trash, items: items)
    }

    func confirm(_ confirmation: VaultItemConfirmation, store: AppStore) {
        self.confirmation = nil
        let ids = Set(confirmation.itemIDs)
        let items = store.items.filter { ids.contains($0.id) }
        switch confirmation.kind {
        case .trash:
            trash(items, store: store)
        case .deletePermanently:
            deleteCount += 1
            Task {
                for item in items {
                    if await store.permanentlyDelete(item), store.selectedItemID == item.id {
                        store.selectedItemID = nil
                    }
                }
            }
        }
    }

    private func announce(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private static func value(_ field: CopyField, of item: VaultItem, store: AppStore) -> String? {
        switch field {
        case .username:
            return item.username.isEmpty || store.isLocked ? nil : item.username
        case .password:
            guard store.canCopyLoginPassword(item), !item.password.isEmpty else { return nil }
            return item.password
        case .code:
            guard store.canCopyVaultSecrets(item), let secret = item.totpSecret else { return nil }
            return TOTPGenerator.code(secret: secret)
        }
    }
}

/// An item's full menu. Copy first, then opening, then organizing, then the
/// destructive actions, as Apple orders them.
struct VaultItemMenu: View {
    let item: VaultItem
    let actions: VaultItemActionModel
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        let permissions = VaultItemPermissions(item: item, store: store)

        Section {
            if item.type == .login, !item.username.isEmpty {
                Button("Copy User Name", systemImage: "person") {
                    actions.copy(.username, from: item, store: store)
                }
            }
            if permissions.canCopyPassword {
                Button("Copy Password", systemImage: "key") {
                    actions.copy(.password, from: item, store: store)
                }
            }
            if permissions.canCopyCode {
                Button("Copy Code", systemImage: "lock.rotation") {
                    actions.copy(.code, from: item, store: store)
                }
            }
            if let url = VaultItemPresentation.websiteURL(for: item) {
                Button("Open Website", systemImage: "safari") { openURL(url) }
            }
        }

        if permissions.canEdit, !item.isDeleted {
            Section {
                Button(
                    item.isFavorite ? L10n.string("Remove from Favorites") : L10n.string("Add to Favorites"),
                    systemImage: item.isFavorite ? "star.slash" : "star"
                ) {
                    actions.toggleFavorite(item, store: store)
                }
                if !store.folders.isEmpty {
                    Menu("Move to Folder", systemImage: "folder") {
                        Picker("Folder", selection: folderBinding) {
                            Text("No Folder").tag("")
                            ForEach(store.sortedFolders) { folder in
                                Text(folder.name).tag(folder.name)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
        }

        if permissions.canEdit {
            Section {
                if item.isDeleted {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        actions.restore([item], store: store)
                    }
                    Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                        actions.requestPermanentDeletion([item])
                    }
                } else {
                    Button(
                        item.isArchived ? L10n.string("Unarchive") : L10n.string("Archive"),
                        systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox"
                    ) {
                        actions.archive([item], store: store)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        actions.trash([item], store: store)
                    }
                }
            }
        }
    }

    private var folderBinding: Binding<String> {
        Binding(
            get: { item.folder ?? "" },
            set: { actions.move(item, toFolder: $0, store: store) }
        )
    }
}

/// Presents what the actions need: the permanent-delete question, the brief
/// "Copied" notice and the haptics.
struct VaultItemActionHost: ViewModifier {
    @ObservedObject var actions: VaultItemActionModel
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VaultCopyNotice(text: actions.notice)
            }
            .confirmationDialog(
                actions.confirmation?.title ?? "",
                isPresented: isConfirming,
                titleVisibility: .visible,
                presenting: actions.confirmation
            ) { confirmation in
                Button(confirmation.actionTitle, role: .destructive) {
                    actions.confirm(confirmation, store: store)
                }
                Button("Cancel", role: .cancel) { actions.confirmation = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .vaultHaptic(.success, trigger: actions.copyCount)
            .vaultHaptic(.selection, trigger: actions.favoriteCount)
            .vaultHaptic(.impact(weight: .medium), trigger: actions.deleteCount)
    }

    private var isConfirming: Binding<Bool> {
        Binding(
            get: { actions.confirmation != nil },
            set: { if !$0 { actions.confirmation = nil } }
        )
    }
}

extension View {
    func vaultItemActions(_ actions: VaultItemActionModel) -> some View {
        modifier(VaultItemActionHost(actions: actions))
    }
}

/// A small capsule that confirms a copy where no field changed to say so.
private struct VaultCopyNotice: View {
    let text: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let text {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(VaultMotion.snappy, value: text)
        .padding(.bottom, 20)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
