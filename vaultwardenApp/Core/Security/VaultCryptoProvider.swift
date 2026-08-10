import CommonCrypto
import Foundation

nonisolated protocol VaultCryptoProvider: Sendable {
    /// Produces only the authentication proof sent to Identity.
    func authenticationHash(
        email: String,
        masterPassword: String,
        kdf: KDFConfiguration
    ) async throws -> String

    func unwrapUserKey(
        userID: String,
        email: String,
        masterPassword: String,
        kdf: KDFConfiguration,
        protectedUserKey: String,
        accountKeys: WrappedAccountKeys
    ) async throws -> Data
}

enum VaultCryptoError: LocalizedError, Equatable {
    case invalidKDFParameters
    case argon2ProviderUnavailable
    case keyDerivationFailed(Int32)
    case missingAccountKeys
    case invalidUserKey
    case sdkFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidKDFParameters:
            "The server returned unsafe or invalid key-derivation parameters."
        case .argon2ProviderUnavailable:
            "This account uses Argon2id. A reviewed Argon2 provider must be added before this account can sign in."
        case .keyDerivationFailed:
            "The device could not derive the account key."
        case .missingAccountKeys:
            "The server did not return the encrypted account keys required to unlock the vault."
        case .invalidUserKey:
            "The decrypted user key has an invalid format."
        case let .sdkFailure(message):
            "Bitwarden crypto failed: \(message)"
        }
    }
}

struct AppleVaultCryptoProvider: VaultCryptoProvider {
    private static let maximumPBKDF2Iterations = 10_000_000

    func authenticationHash(
        email: String,
        masterPassword: String,
        kdf: KDFConfiguration
    ) async throws -> String {
        switch kdf.type {
        case .argon2id:
            throw VaultCryptoError.argon2ProviderUnavailable
        case .pbkdf2SHA256:
            guard (1...Self.maximumPBKDF2Iterations).contains(kdf.iterations) else {
                throw VaultCryptoError.invalidKDFParameters
            }

            let normalizedEmail = email
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let passwordBytes = Data(masterPassword.utf8)
            let emailBytes = Data(normalizedEmail.utf8)
            let masterKey = try PBKDF2SHA256.derive(
                password: passwordBytes,
                salt: emailBytes,
                iterations: kdf.iterations,
                outputByteCount: 32
            )
            let authenticationKey = try PBKDF2SHA256.derive(
                password: masterKey,
                salt: passwordBytes,
                iterations: 1,
                outputByteCount: 32
            )
            return authenticationKey.base64EncodedString()
        }
    }

    func unwrapUserKey(
        userID: String,
        email: String,
        masterPassword: String,
        kdf: KDFConfiguration,
        protectedUserKey: String,
        accountKeys: WrappedAccountKeys
    ) async throws -> Data {
        throw VaultCryptoError.argon2ProviderUnavailable
    }
}

nonisolated enum PBKDF2SHA256 {
    static func derive(
        password: Data,
        salt: Data,
        iterations: Int,
        outputByteCount: Int
    ) throws -> Data {
        guard iterations > 0,
              iterations <= Int(UInt32.max),
              outputByteCount > 0 else {
            throw VaultCryptoError.invalidKDFParameters
        }

        var output = Data(count: outputByteCount)
        let status: Int32 = output.withUnsafeMutableBytes { outputBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        outputBuffer.count
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw VaultCryptoError.keyDerivationFailed(status)
        }
        return output
    }
}

#if DEBUG
enum CryptoKnownAnswerValidator {
    static func validate() -> Bool {
        let expected = Data([
            0x12, 0x0f, 0xb6, 0xcf, 0xfc, 0xf8, 0xb3, 0x2c,
            0x43, 0xe7, 0x22, 0x52, 0x56, 0xc4, 0xf8, 0x37,
            0xa8, 0x65, 0x48, 0xc9, 0x2c, 0xcc, 0x35, 0x48,
            0x08, 0x05, 0x98, 0x7c, 0xb7, 0x0b, 0xe1, 0x7b
        ])
        let result = try? PBKDF2SHA256.derive(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 1,
            outputByteCount: 32
        )
        return result == expected
    }
}
#endif
