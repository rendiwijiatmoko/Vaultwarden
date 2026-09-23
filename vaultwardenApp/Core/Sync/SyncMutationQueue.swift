import CryptoKit
import Foundation
import Security

nonisolated enum VaultMutationEntity: String, Codable, Sendable {
    case cipher
    case folder
    case send
    case sendPassword
}

nonisolated enum VaultMutationState: String, Codable, Sendable {
    case pending
    case conflicted
    case failed
}

/// A local projection is stored with the encrypted request so a cached `/sync`
/// response can never erase edits that have not reached the server yet.
nonisolated enum VaultMutationProjection: Codable, Sendable {
    case upsertItem(VaultItem)
    case trashItem(id: UUID, deletedAt: Date)
    case restoreItem(id: UUID)
    case archiveItem(id: UUID, archivedAt: Date)
    case unarchiveItem(id: UUID)
    case deleteItem(id: UUID)
    case upsertFolder(folder: VaultFolder, previousName: String?)
    case deleteFolder(id: UUID, name: String)
    case upsertSend(SendItem)
    case deleteSend(id: UUID)
}

nonisolated struct PreparedVaultMutation: Identifiable, Codable, Sendable {
    var id = UUID()
    let accountReference: String
    let entity: VaultMutationEntity
    let entityID: String
    var method: String
    var path: String
    var body: Data? = nil
    var projection: VaultMutationProjection
    var baseRevision: Date? = nil
    var createdAt = Date()
    var attemptCount = 0
    var revisionRetryCount = 0
    var nextAttemptAt = Date()
    var lastError: String?
    var state = VaultMutationState.pending

    var isCreate: Bool { method == "POST" }
}

nonisolated enum MutationQueueError: LocalizedError {
    case invalidKey
    case invalidPayload
    case keychain(OSStatus)
    case random(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "The offline change queue key is invalid."
        case .invalidPayload: "The encrypted offline change queue is damaged."
        case let .keychain(status): "The offline change queue Keychain access failed (\(status))."
        case let .random(status): "The offline change queue key could not be generated (\(status))."
        }
    }
}

actor SyncMutationQueue {
    private let keychainService = "xyz.0xmwehehe.vaultwardenApp.mutation-queue"

    func enqueue(_ mutation: PreparedVaultMutation) throws {
        var values = try load(reference: mutation.accountReference)

        if let index = values.lastIndex(where: {
            $0.entity == mutation.entity && $0.entityID == mutation.entityID && $0.state == .pending
        }) {
            let existing = values[index]
            if existing.isCreate {
                if mutation.isDeleteProjection {
                    values.remove(at: index)
                    try save(values, reference: mutation.accountReference)
                    return
                }
                var replacement = mutation
                replacement.id = existing.id
                replacement.method = existing.method
                replacement.path = existing.path
                replacement.createdAt = existing.createdAt
                values[index] = replacement
                try save(values, reference: mutation.accountReference)
                return
            }

            var replacement = mutation
            replacement.id = existing.id
            replacement.createdAt = existing.createdAt
            values[index] = replacement
            try save(values, reference: mutation.accountReference)
            return
        }

        values.append(mutation)
        try save(values, reference: mutation.accountReference)
    }

    func all(reference: String) throws -> [PreparedVaultMutation] {
        try load(reference: reference)
    }

    func ready(reference: String, at date: Date = Date()) throws -> [PreparedVaultMutation] {
        try load(reference: reference)
            .filter { $0.state == .pending && $0.nextAttemptAt <= date }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func update(_ mutation: PreparedVaultMutation) throws {
        var values = try load(reference: mutation.accountReference)
        guard let index = values.firstIndex(where: { $0.id == mutation.id }) else { return }
        values[index] = mutation
        try save(values, reference: mutation.accountReference)
    }

    func remove(id: UUID, reference: String) throws {
        var values = try load(reference: reference)
        values.removeAll { $0.id == id }
        try save(values, reference: reference)
    }

    func resetBlocked(reference: String) throws {
        var values = try load(reference: reference)
        for index in values.indices where values[index].state != .pending {
            values[index].state = .pending
            values[index].nextAttemptAt = Date()
            values[index].lastError = nil
        }
        try save(values, reference: reference)
    }

    func delete(reference: String) throws {
        let url = try queueURL(reference: reference)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let status = SecItemDelete(keyQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MutationQueueError.keychain(status)
        }
    }

    private func load(reference: String) throws -> [PreparedVaultMutation] {
        let url = try queueURL(reference: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let encrypted = try Data(contentsOf: url)
        let key = try queueKey(reference: reference, createIfMissing: false)
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(box, using: key),
              let values = try? JSONDecoder().decode([PreparedVaultMutation].self, from: data) else {
            throw MutationQueueError.invalidPayload
        }
        return values
    }

    private func save(_ values: [PreparedVaultMutation], reference: String) throws {
        let url = try queueURL(reference: reference)
        if values.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let data = try JSONEncoder().encode(values)
        let key = try queueKey(reference: reference, createIfMissing: true)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw MutationQueueError.invalidPayload }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: url, options: ClientPlatform.encryptedFileWritingOptions)
    }

    private func queueURL(reference: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let digest = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("MutationQueue", isDirectory: true)
            .appendingPathComponent("\(digest).queue", isDirectory: false)
    }

    private func queueKey(reference: String, createIfMissing: Bool) throws -> SymmetricKey {
        var query = keyQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw MutationQueueError.invalidKey }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound, createIfMissing else { throw MutationQueueError.keychain(status) }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw MutationQueueError.random(randomStatus) }
        let data = Data(bytes)
        var add = keyQuery(reference: reference)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw MutationQueueError.keychain(addStatus) }
        return SymmetricKey(data: data)
    }

    private func keyQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: reference
        ]
    }
}

private extension PreparedVaultMutation {
    nonisolated var isDeleteProjection: Bool {
        switch projection {
        case .deleteItem, .deleteFolder, .deleteSend: true
        default: false
        }
    }
}
