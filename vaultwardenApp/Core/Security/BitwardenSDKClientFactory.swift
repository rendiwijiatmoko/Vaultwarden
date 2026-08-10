import BitwardenSdk
import Foundation

nonisolated final class EmptySDKTokenProvider: ClientManagedTokens, @unchecked Sendable {
    func getAccessToken() async -> String? { nil }
}

/// The current Bitwarden SDK requires a local-user-data-key repository during
/// crypto initialization, even when the caller only needs to unwrap a vault key.
/// This repository is intentionally ephemeral because generator history and other
/// SDK-owned local data are not persisted by this app yet.
nonisolated actor EphemeralLocalUserDataKeyRepository: LocalUserDataKeyStateRepository {
    private var values: [String: LocalUserDataKeyState] = [:]

    func get(id: String) async throws -> LocalUserDataKeyState? {
        values[id]
    }

    func list() async throws -> [LocalUserDataKeyState] {
        Array(values.values)
    }

    func set(id: String, value: LocalUserDataKeyState) async throws {
        values[id] = value
    }

    func setBulk(values newValues: [String: LocalUserDataKeyState]) async throws {
        values.merge(newValues) { _, new in new }
    }

    func remove(id: String) async throws {
        values.removeValue(forKey: id)
    }

    func removeBulk(keys: [String]) async throws {
        for key in keys {
            values.removeValue(forKey: key)
        }
    }

    func removeAll() async throws {
        values.removeAll(keepingCapacity: false)
    }

    func has(id: String) async throws -> Bool {
        values[id] != nil
    }
}

nonisolated enum BitwardenSDKClientFactory {
    static func make() -> Client {
        let client = Client(tokenProvider: EmptySDKTokenProvider(), settings: nil)
        client.platform().state().registerClientManagedRepositories(
            repositories: Repositories(
                cipher: nil,
                folder: nil,
                userKeyState: nil,
                localUserDataKeyState: EphemeralLocalUserDataKeyRepository(),
                ephemeralPinEnvelopeState: nil,
                organizationSharedKey: nil,
                send: nil
            )
        )
        return client
    }
}
