import CryptoKit
import Foundation
import Security

nonisolated struct VaultArchivePayload: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let items: [VaultItem]
    let folders: [VaultFolder]
    let excludedOrganizationItems: Int
    let excludedPasskeys: Int
}

nonisolated struct VaultArchiveImportSummary: Sendable {
    let importedItems: Int
    let importedFolders: Int
    let failedItems: Int
}

nonisolated enum VaultArchiveError: LocalizedError, Equatable {
    case passwordTooShort
    case invalidArchive
    case unsupportedVersion(Int)
    case authenticationFailed
    case randomGenerationFailed(OSStatus)
    case vaultLocked
    case signedOut

    var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            "Use an export password containing at least 12 characters."
        case .invalidArchive:
            "This is not a valid encrypted Vaultwarden archive."
        case let .unsupportedVersion(version):
            "This archive uses unsupported format version \(version)."
        case .authenticationFailed:
            "The password is incorrect or the archive was modified."
        case let .randomGenerationFailed(status):
            "Secure random generation failed (Security error \(status))."
        case .vaultLocked:
            "Unlock the vault before importing or exporting."
        case .signedOut:
            "Sign in before importing or exporting."
        }
    }
}

nonisolated enum EncryptedVaultArchive {
    private static let format = "xyz.0xmwehehe.vaultwarden.encrypted-archive"
    private static let iterations = 600_000

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: Data
        let sealedPayload: Data
    }

    static func seal(_ payload: VaultArchivePayload, password: String) throws -> Data {
        guard password.count >= 12 else { throw VaultArchiveError.passwordTooShort }
        let salt = try randomData(count: 16)
        let keyData = try PBKDF2SHA256.derive(
            password: Data(password.utf8),
            salt: salt,
            iterations: iterations,
            outputByteCount: 32
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw VaultArchiveError.invalidArchive }
        return try encoder.encode(Envelope(
            format: format,
            version: VaultArchivePayload.currentVersion,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt,
            sealedPayload: combined
        ))
    }

    static func open(_ archive: Data, password: String) throws -> VaultArchivePayload {
        guard password.count >= 12 else { throw VaultArchiveError.passwordTooShort }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: archive),
              envelope.format == format,
              envelope.kdf == "PBKDF2-HMAC-SHA256",
              envelope.iterations > 0,
              envelope.iterations <= 10_000_000,
              envelope.salt.count >= 16 else {
            throw VaultArchiveError.invalidArchive
        }
        guard envelope.version == VaultArchivePayload.currentVersion else {
            throw VaultArchiveError.unsupportedVersion(envelope.version)
        }
        let keyData = try PBKDF2SHA256.derive(
            password: Data(password.utf8),
            salt: envelope.salt,
            iterations: envelope.iterations,
            outputByteCount: 32
        )
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealedPayload),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
            throw VaultArchiveError.authenticationFailed
        }
        do {
            let payload = try decoder.decode(VaultArchivePayload.self, from: plaintext)
            guard payload.version == VaultArchivePayload.currentVersion else {
                throw VaultArchiveError.unsupportedVersion(payload.version)
            }
            return payload
        } catch let error as VaultArchiveError {
            throw error
        } catch {
            throw VaultArchiveError.invalidArchive
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw VaultArchiveError.randomGenerationFailed(status) }
        return Data(bytes)
    }
}
