import Foundation
import Security

nonisolated struct GeneratorHistoryRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let value: String
    let kind: String
    let createdAt: Date
}

nonisolated enum GeneratorHistoryStore {
    static let keychainService = "xyz.0xmwehehe.vaultwardenApp.generator-history"
    private static let account = "history"
    private static let maximumRecordCount = 25

    static func load() throws -> [GeneratorHistoryRecord] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw LocalAccountDataPurgeError.keychain(status)
        }
        return try JSONDecoder().decode([GeneratorHistoryRecord].self, from: data)
    }

    static func add(value: String, kind: String) throws {
        guard !value.isEmpty else { return }
        var records = try load()
        if records.first?.value == value { return }
        records.insert(GeneratorHistoryRecord(value: value, kind: kind, createdAt: Date()), at: 0)
        if records.count > maximumRecordCount {
            records.removeLast(records.count - maximumRecordCount)
        }
        try save(records)
    }

    static func delete(id: UUID) throws {
        var records = try load()
        records.removeAll { $0.id == id }
        try save(records)
    }

    static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalAccountDataPurgeError.keychain(status)
        }
    }

    private static func save(_ records: [GeneratorHistoryRecord]) throws {
        if records.isEmpty {
            try clear()
            return
        }
        let data = try JSONEncoder().encode(records)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw LocalAccountDataPurgeError.keychain(updateStatus)
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LocalAccountDataPurgeError.keychain(addStatus)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }
}
