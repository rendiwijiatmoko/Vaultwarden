import Foundation
import LocalAuthentication
import Security

nonisolated struct StoredSessionCredentials: Codable, Sendable {
    let userID: String?
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date
    let protectedUserKey: String?
    let protectedPrivateKey: String?
    let kdf: KDFConfiguration?
    let accountKeys: WrappedAccountKeys?
}

nonisolated protocol SessionStore: Sendable {
    func save(_ credentials: StoredSessionCredentials, reference: String) throws
    func load(reference: String) throws -> StoredSessionCredentials
    func delete(reference: String) throws
    func saveVaultKey(_ key: Data, reference: String) throws
    func loadVaultKey(reference: String, reason: String) throws -> Data
}

enum SessionStoreError: LocalizedError {
    case encodingFailed
    case notFound
    case unexpectedData
    case devicePasscodeRequired
    case masterPasswordRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "The session could not be encoded securely."
        case .notFound: "The saved session was not found. Please sign in again."
        case .unexpectedData: "The saved session is damaged. Please sign in again."
        case .masterPasswordRequired: "Unlock with your master password to enable device unlock with the current security settings."
        case .devicePasscodeRequired: "Set a device passcode before saving this vault key."
        case let .keychain(status):
            switch status {
            case errSecUserCanceled: "Authentication was canceled."
            case errSecAuthFailed: "Authentication failed. Try again or use your master password."
            case errSecInteractionNotAllowed: "Unlock your device, then try again."
            default: "The Keychain couldn't complete the request. Try again or use your master password."
            }
        }
    }

    /// The person dismissed the system prompt. Not worth an error message.
    var isUserCancellation: Bool {
        if case let .keychain(status) = self { return status == errSecUserCanceled }
        return false
    }
}

nonisolated final class AccessibilityMigration: @unchecked Sendable {
    static let shared = AccessibilityMigration()
    private let lock = NSLock()
    private var migrated: Set<String> = []

    /// True the first time a reference is seen in this process.
    func claim(_ reference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return migrated.insert(reference).inserted
    }
}

struct KeychainSessionStore: SessionStore {
    private let service = "xyz.0xmwehehe.vaultwardenApp.session"

    func save(_ credentials: StoredSessionCredentials, reference: String) throws {
        guard let encoded = try? JSONEncoder().encode(credentials) else {
            throw SessionStoreError.encodingFailed
        }
        let lookup = baseQuery(reference: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = lookup
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SessionStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw SessionStoreError.keychain(updateStatus)
        }
    }

    func load(reference: String) throws -> StoredSessionCredentials {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw SessionStoreError.notFound }
        guard status == errSecSuccess else { throw SessionStoreError.keychain(status) }
        guard let data = result as? Data,
              var credentials = try? JSONDecoder().decode(StoredSessionCredentials.self, from: data) else {
            throw SessionStoreError.unexpectedData
        }
        // Existing installs used WhenUnlocked. AfterFirstUnlock keeps the
        // device-only token available to the registered BG refresh task.
        // Every authenticated request loads credentials; migrate once per launch.
        if AccessibilityMigration.shared.claim(reference) {
            SecItemUpdate(
                baseQuery(reference: reference) as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
            )
        }
        if let update = try? AutoFillSharedVault.takeWriteSessionUpdate(reference: reference) {
            credentials = StoredSessionCredentials(
                userID: credentials.userID,
                accessToken: update.accessToken,
                refreshToken: update.refreshToken ?? credentials.refreshToken,
                tokenType: update.tokenType,
                expiresAt: update.expiresAt,
                protectedUserKey: credentials.protectedUserKey,
                protectedPrivateKey: credentials.protectedPrivateKey,
                kdf: credentials.kdf,
                accountKeys: credentials.accountKeys
            )
            try? save(credentials, reference: reference)
        }
        return credentials
    }

    func delete(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.keychain(status)
        }
        for shared in [true, false] {
            let keyStatus = SecItemDelete(
                AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: shared) as CFDictionary
            )
            guard keyStatus == errSecSuccess || keyStatus == errSecItemNotFound else {
                throw SessionStoreError.keychain(keyStatus)
            }
        }
    }

    func saveVaultKey(_ key: Data, reference: String) throws {
        try DeviceUnlockPolicy.withLock {
            // Master-password login/unlock must work even when device unlock is off.
            let policy = DeviceUnlockPolicy.current
            guard policy != .disabled else { return }
            let accessControl = try policy.makeAccessControl()

            let lookup = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
            for shared in [true, false] {
                let deleteStatus = SecItemDelete(
                    AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: shared) as CFDictionary
                )
                guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                    throw SessionStoreError.keychain(deleteStatus)
                }
            }

            var addQuery = lookup
            addQuery[kSecValueData as String] = key
            addQuery[kSecAttrAccessControl as String] = accessControl
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SessionStoreError.keychain(addStatus) }
            guard DeviceUnlockPolicy.current == policy else {
                SecItemDelete(lookup as CFDictionary)
                throw SessionStoreError.masterPasswordRequired
            }
        }
    }

    func loadVaultKey(reference: String, reason: String) throws -> Data {
        let policy = DeviceUnlockPolicy.current
        guard policy != .disabled else { throw SessionStoreError.masterPasswordRequired }
        let context = LAContext()
        context.localizedReason = reason
        let result = readVaultKey(reference: reference, shared: true, context: context)
        guard let key = result.data else {
            if result.status == errSecItemNotFound { throw SessionStoreError.masterPasswordRequired }
            throw SessionStoreError.keychain(result.status)
        }
        guard DeviceUnlockPolicy.current == policy else { throw SessionStoreError.masterPasswordRequired }
        // Legacy keys deliberately aren't migrated by device authentication:
        // only the master password can provision the new, stricter item.
        return key
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    private func readVaultKey(
        reference: String,
        shared: Bool,
        context: LAContext
    ) -> (data: Data?, status: OSStatus) {
        var query = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = result as? Data else { return (nil, errSecDecode) }
        return (data, errSecSuccess)
    }
}
