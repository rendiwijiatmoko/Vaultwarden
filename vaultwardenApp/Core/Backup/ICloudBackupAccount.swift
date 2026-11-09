import CryptoKit
import Foundation

/// The signed-in account a backup belongs to: its server and account ID. Every Apple ID
/// shares one Backups folder, so each backup is bound to the account that made it.
nonisolated struct ICloudBackupAccount: Equatable, Sendable {
    /// "https://vault.example.com|taylor@example.com"
    let identity: String

    init(serverURL: URL, accountID: String) {
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        identity = "\(Self.normalizedServer(serverURL))|\(account)"
    }

    /// Scheme and host in lowercase, without default ports, credentials, query or trailing slashes.
    static func normalizedServer(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? url.absoluteString.lowercased()
    }

    /// Remembers on this device which account the stored schedule state belongs to,
    /// without storing the identity itself.
    var storageID: String {
        ICloudBackupHex.string(SHA256.hash(data: Data(identity.utf8)).prefix(16))
    }
}

/// One backup key as one account uses it. The tag names the account without revealing it
/// to anyone who lacks the key, and the sealing key is derived from both, so a backup
/// made for one account can't be opened as another's, even with an edited header.
nonisolated struct ICloudBackupAccountKey: Equatable, Sendable {
    static let fileTagLength = 16

    let keyID: String
    /// HMAC-SHA256(backup key, account identity), in hex.
    let accountTag: String
    let sealingKeyData: Data

    init(key: ICloudBackupKey, account: ICloudBackupAccount) {
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Data(account.identity.utf8), using: key.symmetricKey))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key.symmetricKey,
            salt: tag,
            info: Data("vaultwarden-icloud-backup|\(account.identity)".utf8),
            outputByteCount: ICloudBackupKey.byteCount
        )
        keyID = key.id
        accountTag = ICloudBackupHex.string(tag)
        sealingKeyData = derived.withUnsafeBytes { Data($0) }
    }

    /// The first 8 bytes of the tag, for file names.
    var fileTag: String { String(accountTag.prefix(Self.fileTagLength)) }

    var sealingKey: SymmetricKey { SymmetricKey(data: sealingKeyData) }
}

nonisolated enum ICloudBackupHex {
    static func string<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isHex<S: StringProtocol>(_ text: S, length: Int) -> Bool {
        text.count == length && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
