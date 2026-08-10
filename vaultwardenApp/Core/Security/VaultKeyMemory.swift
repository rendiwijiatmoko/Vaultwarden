import Foundation

/// Keeps decrypted account keys only for the lifetime of an unlocked app session.
actor VaultKeyMemory {
    private var keys: [String: Data] = [:]

    func store(_ key: Data, reference: String) {
        keys[reference] = key
    }

    func load(reference: String) -> Data? {
        keys[reference]
    }

    func clear(reference: String? = nil) {
        if let reference {
            keys.removeValue(forKey: reference)
        } else {
            keys.removeAll(keepingCapacity: false)
        }
    }
}
