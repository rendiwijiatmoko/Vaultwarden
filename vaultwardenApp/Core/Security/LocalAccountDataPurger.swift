import Foundation
import Security

nonisolated enum LocalAccountDataPurgeError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "Protected local account data could not be fully removed (Keychain error \(status))."
        }
    }
}

/// Removes every app-owned credential entry, including orphaned entries from accounts
/// used before the app moved to a single active-account model.
nonisolated enum LocalAccountDataPurger {
    private static let services = [
        "xyz.0xmwehehe.vaultwardenApp.session",
        AutoFillSharedVault.vaultKeyService,
        AutoFillSharedVault.payloadKeyService,
        AutoFillSharedVault.writeSessionUpdateService,
        "xyz.0xmwehehe.vaultwardenApp.offline-cache",
        "xyz.0xmwehehe.vaultwardenApp.mutation-queue",
        GeneratorHistoryStore.keychainService
    ]

    static func purgeKeychainItems() throws {
        var firstFailure: OSStatus?
        for service in services {
            for accessGroup in [nil, AutoFillSharedVault.keychainAccessGroup] as [String?] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
                    kSecAttrService as String: service
                ]
                if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess, status != errSecItemNotFound, firstFailure == nil {
                    firstFailure = status
                }
            }
        }
        if let firstFailure { throw LocalAccountDataPurgeError.keychain(firstFailure) }
    }
}
