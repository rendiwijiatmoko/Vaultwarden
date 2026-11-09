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
    /// Bumped whenever a newer local edit is coalesced into this entry, so a
    /// replay that started earlier cannot remove or overwrite the newer edit.
    /// Optional so queues written by earlier versions still decode.
    var localRevision: Int?

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
        case .keychain: "The offline change queue couldn't be accessed. Unlock your device and try again."
        case .random: "The offline change queue key couldn't be created. Try again."
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
            switch Self.coalescing(existing: existing, incoming: mutation) {
            case .dropBoth:
                values.remove(at: index)
                try save(values, reference: mutation.accountReference)
                return
            case .replace:
                var replacement = mutation
                replacement.id = existing.id
                replacement.createdAt = existing.createdAt
                replacement.localRevision = (existing.localRevision ?? 0) + 1
                if existing.isCreate {
                    // The server has never seen this entity: the edit stays a create.
                    replacement.method = existing.method
                    replacement.path = existing.path
                }
                values[index] = replacement
                try save(values, reference: mutation.accountReference)
                return
            case .append:
                break
            }
        }

        values.append(mutation)
        try save(values, reference: mutation.accountReference)
    }

    nonisolated enum Coalescing: Equatable {
        case dropBoth, replace, append
    }

    /// Only merges requests whose server effect the incoming request fully supersedes.
    /// An edit after a trash or archive must not erase that trash or archive request.
    nonisolated static func coalescing(
        existing: PreparedVaultMutation,
        incoming: PreparedVaultMutation
    ) -> Coalescing {
        if existing.isCreate {
            if incoming.isDeleteProjection { return .dropBoth }
            return incoming.body != nil ? .replace : .append
        }
        if incoming.method == "DELETE" { return .replace }
        if incoming.method == existing.method, incoming.path == existing.path { return .replace }
        return .append
    }

    func all(reference: String) throws -> [PreparedVaultMutation] {
        try load(reference: reference)
    }

    func ready(reference: String, at date: Date = Date()) throws -> [PreparedVaultMutation] {
        try load(reference: reference)
            .filter { $0.state == .pending && $0.nextAttemptAt <= date }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Skips the write when a newer local edit was coalesced in meanwhile.
    func update(_ mutation: PreparedVaultMutation) throws {
        var values = try load(reference: mutation.accountReference)
        guard let index = values.firstIndex(where: { $0.id == mutation.id }),
              values[index].localRevision == mutation.localRevision else { return }
        values[index] = mutation
        try save(values, reference: mutation.accountReference)
    }

    func remove(id: UUID, reference: String) throws {
        var values = try load(reference: reference)
        values.removeAll { $0.id == id }
        try save(values, reference: reference)
    }

    /// Removes a replayed request only if it is still the version that was sent.
    func remove(_ mutation: PreparedVaultMutation) throws {
        var values = try load(reference: mutation.accountReference)
        let count = values.count
        values.removeAll { $0.id == mutation.id && $0.localRevision == mutation.localRevision }
        guard values.count != count else { return }
        try save(values, reference: mutation.accountReference)
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
        try? FileManager.default.removeItem(at: url.appendingPathExtension("unreadable"))
        let status = SecItemDelete(keyQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MutationQueueError.keychain(status)
        }
    }

    private func load(reference: String) throws -> [PreparedVaultMutation] {
        let url = try queueURL(reference: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let encrypted = try Data(contentsOf: url)
        let key: SymmetricKey
        do {
            key = try queueKey(reference: reference, createIfMissing: false)
        } catch let MutationQueueError.keychain(status) where status == errSecItemNotFound {
            // The device-only key is gone (restored backup, Keychain reset). The file
            // can never be opened again; keeping it would block every future save.
            try? quarantine(url)
            return []
        }
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(box, using: key) else {
            throw MutationQueueError.invalidPayload
        }
        guard let values = try? JSONDecoder().decode([PreparedVaultMutation].self, from: data) else {
            // Authentic but unreadable by this version. Set it aside instead of
            // failing every save; it stays encrypted and is purged on sign-out.
            try? quarantine(url)
            SecureLog.event("Unreadable offline change queue set aside", logger: SecureLog.sync)
            return []
        }
        return values
    }

    private func quarantine(_ url: URL) throws {
        let destination = url.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
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
        // The key is device-only, so a backed-up copy could never be opened anyway.
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
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
