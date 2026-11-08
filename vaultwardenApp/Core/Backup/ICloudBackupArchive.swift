import CryptoKit
import Foundation
import Security

nonisolated enum ICloudBackupError: LocalizedError, Equatable {
    case iCloudUnavailable
    case invalidBackup
    case unsupportedVersion(Int)
    case authenticationFailed
    case keyUnavailable
    case randomGenerationFailed(OSStatus)
    case keychain(OSStatus)
    case vaultLocked
    case signedOut

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            #if os(macOS)
            return L10n.string("Turn on iCloud Drive in System Settings ▸ Apple Account ▸ iCloud, then try again.")
            #else
            return L10n.string("Turn on iCloud Drive in Settings ▸ Apple Account ▸ iCloud, then try again.")
            #endif
        case .invalidBackup, .authenticationFailed:
            return L10n.string("This backup is damaged and can’t be restored.")
        case .unsupportedVersion:
            return L10n.string("This backup was made by a newer version of Vaultwarden. Update the app to restore it.")
        case .keyUnavailable:
            #if os(macOS)
            return L10n.string("The key for this backup isn’t on this Mac yet. Turn on Passwords & Keychain in System Settings ▸ Apple Account ▸ iCloud, then try again.")
            #else
            return L10n.string("The key for this backup isn’t on this iPhone yet. Turn on Passwords and Keychain in Settings ▸ Apple Account ▸ iCloud, then try again.")
            #endif
        case .randomGenerationFailed, .keychain:
            return L10n.string("Vaultwarden couldn’t use its backup key in iCloud Keychain. Try again.")
        case .vaultLocked:
            return L10n.string("Unlock your vault, then try again.")
        case .signedOut:
            return L10n.string("Sign in, then try again.")
        }
    }
}

/// A 256-bit backup key. Its `id` is a fingerprint, so a backup names the key it needs
/// without saying anything about the key.
nonisolated struct ICloudBackupKey: Equatable, Sendable {
    static let byteCount = 32

    let id: String
    let data: Data

    init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
        id = Self.identifier(for: data)
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: data) }

    static func generate() throws -> ICloudBackupKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess, let key = ICloudBackupKey(data: Data(bytes)) else {
            throw ICloudBackupError.randomGenerationFailed(status)
        }
        return key
    }

    static func identifier(for data: Data) -> String {
        var input = Data("xyz.0xmwehehe.vaultwarden.icloud-backup.key-id".utf8)
        input.append(contentsOf: [0])
        input.append(data)
        return SHA256.hash(data: input).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Readable without the key, and authenticated by every sealed part, so restore can tell
/// which key a file needs and any change to it fails.
nonisolated struct ICloudBackupHeader: Codable, Equatable, Sendable {
    static let formatIdentifier = "xyz.0xmwehehe.vaultwarden.icloud-backup"
    static let currentVersion = 1

    var format: String
    var version: Int
    var backupID: UUID
    var keyID: String
    var createdAt: Date
}

/// Sealed separately from the vault, so listing backups never decrypts any items.
nonisolated struct ICloudBackupMetadata: Codable, Equatable, Sendable {
    var itemCount: Int
    var folderCount: Int
    /// HMAC of the vault contents under the backup key, to skip backups that change nothing.
    var contentDigest: Data
}

nonisolated struct ICloudBackupContents: Sendable {
    let header: ICloudBackupHeader
    let metadata: ICloudBackupMetadata
    let payload: VaultArchivePayload
}

nonisolated enum ICloudBackupArchive {
    private struct Envelope: Codable {
        /// The exact header bytes the sealed parts authenticate.
        let header: Data
        let metadata: Data
        let payload: Data
    }

    private enum Part: String {
        case metadata
        case payload
    }

    private struct DigestInput: Encodable {
        let items: [VaultItem]
        let folders: [VaultFolder]
    }

    private static let stableFieldID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// The same contents as the encrypted export: personal, non-deleted items and every
    /// folder; no organization items, attachment files or passkey material.
    static func payload(items: [VaultItem], folders: [VaultFolder], exportedAt: Date) -> VaultArchivePayload {
        let personalItems = items.filter { !$0.isDeleted && $0.organization == nil }
        return VaultArchivePayload(
            version: VaultArchivePayload.currentVersion,
            exportedAt: exportedAt,
            items: personalItems.map { item in
                var copy = item
                copy.passkeyCount = 0
                copy.attachments = nil
                return copy
            },
            folders: folders,
            excludedOrganizationItems: items.filter { $0.organization != nil }.count,
            excludedPasskeys: personalItems.reduce(0) { $0 + $1.passkeyCount }
        )
    }

    static func seal(
        _ payload: VaultArchivePayload,
        metadata: ICloudBackupMetadata,
        key: ICloudBackupKey,
        backupID: UUID,
        createdAt: Date
    ) throws -> Data {
        let encoder = makeEncoder()
        let header = ICloudBackupHeader(
            format: ICloudBackupHeader.formatIdentifier,
            version: ICloudBackupHeader.currentVersion,
            backupID: backupID,
            keyID: key.id,
            createdAt: createdAt
        )
        let headerData = try encoder.encode(header)
        let sealedMetadata = try sealPart(encoder.encode(metadata), part: .metadata, header: headerData, key: key)
        let sealedPayload = try sealPart(encoder.encode(payload), part: .payload, header: headerData, key: key)
        return try encoder.encode(Envelope(header: headerData, metadata: sealedMetadata, payload: sealedPayload))
    }

    /// Unauthenticated: only for choosing the key. `open` verifies it.
    static func header(of archive: Data) throws -> ICloudBackupHeader {
        try decode(archive).header
    }

    static func openMetadata(_ archive: Data, key: ICloudBackupKey) throws -> (header: ICloudBackupHeader, metadata: ICloudBackupMetadata) {
        let (envelope, header) = try decode(archive)
        let plaintext = try openPart(envelope.metadata, part: .metadata, header: envelope.header, key: key)
        guard let metadata = try? makeDecoder().decode(ICloudBackupMetadata.self, from: plaintext) else {
            throw ICloudBackupError.invalidBackup
        }
        return (header, metadata)
    }

    static func open(_ archive: Data, key: ICloudBackupKey) throws -> ICloudBackupContents {
        let (envelope, header) = try decode(archive)
        let decoder = makeDecoder()
        let metadataPlaintext = try openPart(envelope.metadata, part: .metadata, header: envelope.header, key: key)
        let payloadPlaintext = try openPart(envelope.payload, part: .payload, header: envelope.header, key: key)
        guard let metadata = try? decoder.decode(ICloudBackupMetadata.self, from: metadataPlaintext),
              let payload = try? decoder.decode(VaultArchivePayload.self, from: payloadPlaintext) else {
            throw ICloudBackupError.invalidBackup
        }
        guard payload.version == VaultArchivePayload.currentVersion else {
            throw ICloudBackupError.unsupportedVersion(payload.version)
        }
        return ICloudBackupContents(header: header, metadata: metadata, payload: payload)
    }

    /// Keyed, and blind to what changes on every sync without changing the vault: the
    /// analyzer's risk flags, custom field identifiers, the order items arrive in.
    static func contentDigest(of payload: VaultArchivePayload, key: ICloudBackupKey) throws -> Data {
        let items = payload.items
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { item in
                var copy = item
                copy.risks = []
                copy.customFields = copy.customFields.map { field in
                    var stable = field
                    stable.id = stableFieldID
                    return stable
                }
                return copy
            }
        let folders = payload.folders.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(DigestInput(items: items, folders: folders))
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key.symmetricKey))
    }

    private static func decode(_ archive: Data) throws -> (envelope: Envelope, header: ICloudBackupHeader) {
        let decoder = makeDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: archive),
              let header = try? decoder.decode(ICloudBackupHeader.self, from: envelope.header),
              header.format == ICloudBackupHeader.formatIdentifier,
              !header.keyID.isEmpty else {
            throw ICloudBackupError.invalidBackup
        }
        guard header.version == ICloudBackupHeader.currentVersion else {
            throw ICloudBackupError.unsupportedVersion(header.version)
        }
        return (envelope, header)
    }

    private static func sealPart(_ plaintext: Data, part: Part, header: Data, key: ICloudBackupKey) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: key.symmetricKey,
            authenticating: associatedData(for: part, header: header)
        )
        guard let combined = box.combined else { throw ICloudBackupError.invalidBackup }
        return combined
    }

    private static func openPart(_ sealed: Data, part: Part, header: Data, key: ICloudBackupKey) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(
                  box,
                  using: key.symmetricKey,
                  authenticating: associatedData(for: part, header: header)
              ) else {
            throw ICloudBackupError.authenticationFailed
        }
        return plaintext
    }

    /// Names the part as well as the header, so the metadata and payload boxes can't be swapped.
    private static func associatedData(for part: Part, header: Data) -> Data {
        var data = Data("\(ICloudBackupHeader.formatIdentifier).\(part.rawValue)".utf8)
        data.append(contentsOf: [0])
        data.append(header)
        return data
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
