import BitwardenSdk
import Foundation

nonisolated struct GeneratedSSHKey: Sendable {
    let privateKey: String
    let publicKey: String
    let fingerprint: String
}

/// Uses the pinned SDK's OpenSSH encoder and cryptographically secure RNG.
/// Key material is returned in memory and never enters generator history.
nonisolated enum SSHKeyGenerator {
    static func generate(comment: String = "") throws -> GeneratedSSHKey {
        let key = try BitwardenSDKClientFactory.make().ssh().generateSshKey(keyAlgorithm: .ed25519)
        let comment = comment.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedSSHKey(
            privateKey: key.privateKey,
            publicKey: comment.isEmpty ? key.publicKey : "\(key.publicKey) \(comment)",
            fingerprint: key.fingerprint
        )
    }
}
