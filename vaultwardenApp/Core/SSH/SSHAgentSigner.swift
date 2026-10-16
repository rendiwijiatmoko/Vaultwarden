#if os(macOS)
import BitwardenSdk
import CryptoKit
import Foundation
import Security

nonisolated enum SSHAgentSigner {
    static func publicBlob(_ publicKey: String) throws -> Data {
        let fields = publicKey.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, fields[1].count <= 16_384,
              let blob = Data(base64Encoded: String(fields[1])) else { throw SSHAgentError.invalidKey }
        var reader = SSHWireReader(data: blob)
        let algorithm = try reader.text()
        guard algorithm == fields[0] else { throw SSHAgentError.invalidKey }
        switch algorithm {
        case "ssh-ed25519":
            guard try reader.string().count == 32 else { throw SSHAgentError.invalidKey }
        case "ssh-rsa":
            let exponent = try positiveInteger(reader.string())
            let modulus = try positiveInteger(reader.string())
            guard exponent.count <= 8, modulus.count >= 256, modulus.count <= 512 else {
                throw SSHAgentError.invalidKey
            }
        default: throw SSHAgentError.unsupportedKey
        }
        guard reader.isAtEnd else { throw SSHAgentError.invalidKey }
        return blob
    }

    static func fingerprint(_ blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func sign(privateKey: String, publicKey: Data, message: Data, flags: UInt32) throws -> Data {
        guard privateKey.utf8.count <= SSHAgentRequest.maximumFrameSize else { throw SSHAgentError.invalidKey }
        // Canonicalize supported imported PKCS#8/OpenSSH keys through the existing SDK.
        let canonical = try BitwardenSDKClientFactory.make().ssh().importSshKey(importedKey: privateKey, password: nil)
        guard try publicBlob(canonical.publicKey) == publicKey else { throw SSHAgentError.invalidKey }
        let body = canonical.privateKey.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body), data.count <= SSHAgentRequest.maximumFrameSize else {
            throw SSHAgentError.invalidKey
        }
        var envelope = SSHWireReader(data: data)
        guard try envelope.bytes(15) == Data("openssh-key-v1\0".utf8),
              try envelope.text() == "none", try envelope.text() == "none",
              try envelope.string().isEmpty, try envelope.uint32() == 1,
              try envelope.string() == publicKey else { throw SSHAgentError.invalidKey }
        var key = SSHWireReader(data: try envelope.string())
        guard envelope.isAtEnd, try key.uint32() == key.uint32() else { throw SSHAgentError.invalidKey }
        let algorithm = try key.text()
        let response: Data
        switch algorithm {
        case "ssh-ed25519":
            guard flags == 0 else { throw SSHAgentError.invalidMessage }
            let publicBytes = try key.string()
            let privateBytes = try key.string()
            guard publicBytes.count == 32, privateBytes.count == 64,
                  privateBytes.suffix(32) == publicBytes else { throw SSHAgentError.invalidKey }
            let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes.prefix(32))
            guard signer.publicKey.rawRepresentation == publicBytes,
                  SSHWire.text(algorithm) + SSHWire.string(publicBytes) == publicKey else { throw SSHAgentError.invalidKey }
            response = SSHAgentRequest.signature(algorithm: algorithm, value: try signer.signature(for: message))
        case "ssh-rsa":
            guard flags == 2 || flags == 4 || flags == 6 else { throw SSHAgentError.unsupportedKey }
            let n = try positiveInteger(key.string())
            let e = try positiveInteger(key.string())
            let d = try positiveInteger(key.string())
            let iqmp = try positiveInteger(key.string())
            let p = try positiveInteger(key.string())
            let q = try positiveInteger(key.string())
            guard n.count >= 256, n.count <= 512,
                  d.count <= n.count, p.count <= n.count, q.count <= n.count,
                  e.count <= 8, iqmp.count <= n.count else { throw SSHAgentError.invalidKey }
            let dp = try remainder(d, modulo: subtractOne(p))
            let dq = try remainder(d, modulo: subtractOne(q))
            let der = sequence([Data([0]), n, e, d, p, q, dp, dq, iqmp].map(integer))
            var error: Unmanaged<CFError>?
            guard let signer = SecKeyCreateWithData(der as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate
            ] as CFDictionary, &error), let verificationKey = SecKeyCopyPublicKey(signer),
                  let encodedPublic = SecKeyCopyExternalRepresentation(verificationKey, &error),
                  encodedPublic as Data == sequence([integer(n), integer(e)]) else { throw SSHAgentError.invalidKey }
            let signatureAlgorithm: SecKeyAlgorithm = flags & 4 != 0
                ? .rsaSignatureMessagePKCS1v15SHA512 : .rsaSignatureMessagePKCS1v15SHA256
            guard let signature = SecKeyCreateSignature(signer, signatureAlgorithm, message as CFData, &error),
                  SecKeyVerifySignature(verificationKey, signatureAlgorithm, message as CFData, signature, &error) else {
                throw SSHAgentError.invalidKey
            }
            response = SSHAgentRequest.signature(algorithm: flags & 4 != 0 ? "rsa-sha2-512" : "rsa-sha2-256",
                                                   value: signature as Data)
        default: throw SSHAgentError.unsupportedKey
        }
        _ = try key.string() // Private key comment.
        let padding = try key.bytes(key.data.count - key.offset)
        guard key.data.count % 8 == 0, padding.count <= 8,
              padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else {
            throw SSHAgentError.invalidKey
        }
        return response
    }

    private static func positiveInteger(_ bytes: Data) throws -> Data {
        guard let first = bytes.first, first & 0x80 == 0, bytes.count <= 1_025 else { throw SSHAgentError.invalidKey }
        let value = Data(bytes.drop(while: { $0 == 0 }))
        guard !value.isEmpty else { throw SSHAgentError.invalidKey }
        return value
    }
    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func integer(_ bytes: Data) -> Data {
        let value = bytes.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + bytes : bytes
        return Data([0x02]) + length(value.count) + value
    }
    private static func sequence(_ values: [Data]) -> Data {
        let body = values.reduce(Data(), +)
        return Data([0x30]) + length(body.count) + body
    }
    private static func subtractOne(_ value: Data) throws -> Data {
        var bytes = Array(value)
        var index = bytes.count - 1
        while index > 0 && bytes[index] == 0 { bytes[index] = 255; index -= 1 }
        guard bytes[index] > 0 else { throw SSHAgentError.invalidKey }
        bytes[index] -= 1
        return Data(bytes.drop(while: { $0 == 0 }))
    }
    /// Binary long division to derive RSA CRT exponents from OpenSSH's d, p, q.
    /// This operates on key material only during an approved signing request.
    private static func remainder(_ dividend: Data, modulo modulus: Data) throws -> Data {
        guard !modulus.isEmpty else { throw SSHAgentError.invalidKey }
        let divisor = Array(modulus)
        var result: [UInt8] = [0]
        for byte in dividend {
            for bit in (0..<8).reversed() {
                var carry = (byte >> bit) & 1
                for i in result.indices.reversed() {
                    let next = result[i] >> 7
                    result[i] = (result[i] << 1) | carry
                    carry = next
                }
                if carry != 0 { result.insert(carry, at: 0) }
                while result.count > 1 && result[0] == 0 { result.removeFirst() }
                if result.count > divisor.count || (result.count == divisor.count && !result.lexicographicallyPrecedes(divisor)) {
                    var borrow = 0
                    for index in result.indices.reversed() {
                        let j = index - (result.count - divisor.count)
                        var difference = Int(result[index]) - (j >= 0 ? Int(divisor[j]) : 0) - borrow
                        borrow = difference < 0 ? 1 : 0
                        if difference < 0 { difference += 256 }
                        result[index] = UInt8(difference)
                    }
                    while result.count > 1 && result[0] == 0 { result.removeFirst() }
                }
            }
        }
        return Data(result)
    }
}
#endif
