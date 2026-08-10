import Foundation

nonisolated struct VaultProjectionState: Sendable {
    var items: [VaultItem]
    var folders: [VaultFolder]
    var sends: [SendItem]
}

nonisolated enum VaultProjectionReducer {
    static func apply(_ projection: VaultMutationProjection, to state: inout VaultProjectionState) {
        switch projection {
        case let .upsertItem(item):
            if let index = state.items.firstIndex(where: { $0.id == item.id }) { state.items[index] = item }
            else { state.items.append(item) }
        case let .trashItem(id, deletedAt):
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index].deletedAt = deletedAt }
        case let .restoreItem(id):
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index].deletedAt = nil }
        case let .archiveItem(id, archivedAt):
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index].archivedAt = archivedAt }
        case let .unarchiveItem(id):
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index].archivedAt = nil }
        case let .deleteItem(id):
            state.items.removeAll { $0.id == id }
        case let .upsertFolder(folder, previousName):
            if let index = state.folders.firstIndex(where: { $0.id == folder.id }) {
                state.folders[index] = folder
            } else if let previousName,
                      let index = state.folders.firstIndex(where: { $0.name == previousName }) {
                state.folders[index] = folder
            } else {
                state.folders.append(folder)
            }
            if let previousName {
                for index in state.items.indices where state.items[index].folder == previousName {
                    state.items[index].folder = folder.name
                }
            }
        case let .deleteFolder(id, name):
            state.folders.removeAll { $0.id == id || $0.name == name }
            for index in state.items.indices where state.items[index].folder == name {
                state.items[index].folder = nil
            }
        case let .upsertSend(send):
            if let index = state.sends.firstIndex(where: { $0.id == send.id }) { state.sends[index] = send }
            else { state.sends.insert(send, at: 0) }
        case let .deleteSend(id):
            state.sends.removeAll { $0.id == id }
        }
    }
}
