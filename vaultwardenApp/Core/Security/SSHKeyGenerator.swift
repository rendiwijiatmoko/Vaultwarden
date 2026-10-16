import BitwardenSdk
import Foundation
import CryptoKit
import Security

nonisolated struct GeneratedSSHKey: Sendable {
    let privateKey: String
    let publicKey: String
    let fingerprint: String
}

nonisolated enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519
    case rsa2048
    case rsa4096

    var id: Self { self }

    var title: String {
        switch self {
        case .ed25519: "Ed25519"
        case .rsa2048: "RSA 2048"
        case .rsa4096: "RSA 4096"
        }
    }
}

/// Generates OpenSSH keys using the pinned SDK or Apple Security.
/// Key material is returned in memory and never enters generator history.
nonisolated enum SSHKeyGenerator {
    static func generate(algorithm: SSHKeyAlgorithm = .ed25519, comment: String = "") throws -> GeneratedSSHKey {
        let key: GeneratedSSHKey
        switch algorithm {
        case .ed25519, .rsa4096:
            let generated = try BitwardenSDKClientFactory.make().ssh().generateSshKey(
                keyAlgorithm: algorithm == .ed25519 ? .ed25519 : .rsa4096
            )
            key = GeneratedSSHKey(privateKey: generated.privateKey, publicKey: generated.publicKey,
                                  fingerprint: generated.fingerprint)
        case .rsa2048:
            key = try generateRSA2048()
        }
        let comment = comment.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedSSHKey(
            privateKey: key.privateKey,
            publicKey: comment.isEmpty ? key.publicKey : "\(key.publicKey) \(comment)",
            fingerprint: key.fingerprint
        )
    }
}

// Security exports RSA private keys as PKCS#1 DER. Encode their integers in
// OpenSSH's unencrypted private-key container, without persisting key material.
private extension SSHKeyGenerator {
    nonisolated enum RSAError: Error { case generationFailed, invalidKey }

    nonisolated static func generateRSA2048() throws -> GeneratedSSHKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw RSAError.generationFailed
        }
        guard let exported = SecKeyCopyExternalRepresentation(key, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw RSAError.generationFailed
        }
        var der = DERReader(bytes: Array(exported as Data))
        var sequence = DERReader(bytes: try der.read(tag: 0x30))
        let version = try sequence.read(tag: 0x02)
        guard version == [0] else { throw RSAError.invalidKey }
        let n = try sequence.read(tag: 0x02)
        let e = try sequence.read(tag: 0x02)
        let d = try sequence.read(tag: 0x02)
        let p = try sequence.read(tag: 0x02)
        let q = try sequence.read(tag: 0x02)
        _ = try sequence.read(tag: 0x02) // d mod (p - 1)
        _ = try sequence.read(tag: 0x02) // d mod (q - 1)
        let iqmp = try sequence.read(tag: 0x02)
        guard der.isAtEnd, sequence.isAtEnd else { throw RSAError.invalidKey }

        let publicBlob = sshString(Array("ssh-rsa".utf8)) + sshString(e) + sshString(n)
        var check = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, check.count, &check) == errSecSuccess else {
            throw RSAError.generationFailed
        }
        var privateBlob = check + check + sshString(Array("ssh-rsa".utf8))
        for integer in [n, e, d, iqmp, p, q] { privateBlob += sshString(integer) }
        privateBlob += sshString([]) // Empty private-key comment.
        let padding = 8 - privateBlob.count % 8
        privateBlob += (1...padding).map(UInt8.init)
        var container = Array("openssh-key-v1\0".utf8)
        container += sshString(Array("none".utf8)) // Cipher.
        container += sshString(Array("none".utf8)) // KDF.
        container += sshString([]) // KDF options.
        container += [0, 0, 0, 1] // One key.
        container += sshString(publicBlob) + sshString(privateBlob)
        let base64 = Array(Data(container).base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 70).map {
            String(base64[$0..<min($0 + 70, base64.count)])
        }.joined(separator: "\n")
        return GeneratedSSHKey(
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines + "\n-----END OPENSSH PRIVATE KEY-----\n",
            publicKey: "ssh-rsa " + Data(publicBlob).base64EncodedString(),
            fingerprint: "SHA256:" + Data(SHA256.hash(data: Data(publicBlob))).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
        )
    }

    nonisolated static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + bytes
    }

    nonisolated struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset == bytes.count }

        mutating func read(tag: UInt8) throws -> [UInt8] {
            guard bytes.count - offset >= 2, bytes[offset] == tag else { throw RSAError.invalidKey }
            offset += 1
            let firstLength = bytes[offset]
            offset += 1
            var length = Int(firstLength)
            if firstLength & 0x80 != 0 {
                let count = Int(firstLength & 0x7f)
                guard (1...4).contains(count), bytes.count - offset >= count else { throw RSAError.invalidKey }
                length = 0
                for _ in 0..<count {
                    length = (length << 8) | Int(bytes[offset])
                    offset += 1
                }
            }
            guard length <= bytes.count - offset else { throw RSAError.invalidKey }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }
    }
}
