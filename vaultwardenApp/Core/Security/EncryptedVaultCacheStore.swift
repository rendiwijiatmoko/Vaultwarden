import CryptoKit
import Foundation
import Security

/// Stores the already field-encrypted `/sync` response inside a second, device-only
/// AES-GCM envelope. The cache key never leaves Keychain.
nonisolated protocol VaultCacheStore: Sendable {
    func save(payload: Data, reference: String) throws
    func load(reference: String) throws -> Data
    func delete(reference: String) throws
}

nonisolated enum VaultCacheError: LocalizedError {
    case keyGenerationFailed(OSStatus)
    case keychain(OSStatus)
    case invalidKey
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(status):
            "Unable to generate the offline cache key (Security error \(status))."
        case let .keychain(status):
            "Unable to access the offline cache key (Keychain error \(status))."
        case .invalidKey:
            "The offline cache key is invalid."
        case .invalidPayload:
            "The encrypted offline vault cache is damaged."
        }
    }
}

nonisolated struct EncryptedVaultCacheStore: VaultCacheStore {
    private let keychainService = "xyz.0xmwehehe.vaultwardenApp.offline-cache"

    func save(payload: Data, reference: String) throws {
        let key = try cacheKey(reference: reference, createIfMissing: true)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw VaultCacheError.invalidPayload }

        let url = try cacheURL(reference: reference)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Background refresh runs after the user has unlocked the device once.
        // The device-only key still prevents migration or backup extraction.
        try combined.write(to: url, options: ClientPlatform.encryptedFileWritingOptions)
    }

    func load(reference: String) throws -> Data {
        let encrypted = try Data(contentsOf: cacheURL(reference: reference))
        let key = try cacheKey(reference: reference, createIfMissing: false)
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let payload = try? AES.GCM.open(box, using: key) else {
            throw VaultCacheError.invalidPayload
        }
        return payload
    }

    func delete(reference: String) throws {
        let url = try cacheURL(reference: reference)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let status = SecItemDelete(keyQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultCacheError.keychain(status)
        }
    }

    private func cacheURL(reference: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let digest = SHA256.hash(data: Data(reference.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root
            .appendingPathComponent("EncryptedVaultCache", isDirectory: true)
            .appendingPathComponent("\(digest).vaultcache", isDirectory: false)
    }

    private func cacheKey(reference: String, createIfMissing: Bool) throws -> SymmetricKey {
        var query = keyQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw VaultCacheError.invalidKey
            }
            // Migrate keys created before background refresh support.
            SecItemUpdate(
                keyQuery(reference: reference) as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
            )
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound, createIfMissing else {
            throw VaultCacheError.keychain(status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw VaultCacheError.keyGenerationFailed(randomStatus)
        }
        let data = Data(bytes)
        var addQuery = keyQuery(reference: reference)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw VaultCacheError.keychain(addStatus) }
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
