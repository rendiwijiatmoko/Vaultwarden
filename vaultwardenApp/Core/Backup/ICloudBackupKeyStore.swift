import Foundation
import Security

/// Where backup keys live. The app uses iCloud Keychain; tests use memory.
nonisolated protocol ICloudBackupKeyStoring: Sendable {
    func keyIDs() throws -> [String]
    func keyData(for id: String) throws -> Data?
    func add(_ keyData: Data, id: String) throws
}

nonisolated enum ICloudBackupKeychain {
    /// The key new backups use. Two devices that each made a key before iCloud Keychain
    /// synced settle on the same one (the lowest ID); keys are never deleted, so backups
    /// sealed with the other stay restorable.
    static func currentKey(in store: any ICloudBackupKeyStoring) throws -> ICloudBackupKey {
        for id in try store.keyIDs().sorted() {
            if let existing = try Self.key(id: id, in: store) { return existing }
        }
        let key = try ICloudBackupKey.generate()
        try store.add(key.data, id: key.id)
        return key
    }

    /// Nil when this device doesn't have the key, or what it has doesn't match the ID.
    static func key(id: String, in store: any ICloudBackupKeyStoring) throws -> ICloudBackupKey? {
        guard let data = try store.keyData(for: id),
              let key = ICloudBackupKey(data: data),
              key.id == id else { return nil }
        return key
    }
}

/// Synchronizable generic passwords, so the key follows the person to a new device
/// through iCloud Keychain, which is end-to-end encrypted.
nonisolated struct ICloudKeychainBackupKeyStore: ICloudBackupKeyStoring {
    private let service = "xyz.0xmwehehe.vaultwardenApp.icloud-backup-key"

    func keyIDs() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ICloudBackupError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func keyData(for id: String) throws -> Data? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ICloudBackupError.keychain(status) }
        return result as? Data
    }

    func add(_ keyData: Data, id: String) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrLabel as String] = "Vaultwarden iCloud Backup Key"
        let status = SecItemAdd(query as CFDictionary, nil)
        // The ID is the key's fingerprint, so a duplicate already holds these bytes.
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ICloudBackupError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: true
        ]
    }
}
