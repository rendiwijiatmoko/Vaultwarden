import BitwardenSdk
import Foundation

nonisolated struct BitwardenSDKCryptoProvider: VaultCryptoProvider {
    func authenticationHash(
        email: String,
        masterPassword: String,
        kdf: KDFConfiguration
    ) async throws -> String {
        do {
            return try await makeClient().auth().hashPassword(
                email: email,
                password: masterPassword,
                kdfParams: try sdkKDF(kdf),
                purpose: .serverAuthorization
            )
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.sdkFailure(error.localizedDescription)
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
        do {
            let client = makeClient()
            let sdkKDF = try sdkKDF(kdf)
            let cryptographicState: WrappedAccountCryptographicState
            if let signingKey = accountKeys.signingKey,
               let signedPublicKey = accountKeys.signedPublicKey,
               let securityState = accountKeys.securityState {
                cryptographicState = .v2(
                    privateKey: accountKeys.privateKey,
                    signedPublicKey: signedPublicKey,
                    signingKey: signingKey,
                    securityState: securityState
                )
            } else {
                cryptographicState = .v1(privateKey: accountKeys.privateKey)
            }

            try await client.crypto().initializeUserCrypto(
                req: InitUserCryptoRequest(
                    userId: userID,
                    kdfParams: sdkKDF,
                    email: email,
                    accountCryptographicState: cryptographicState,
                    method: .masterPasswordUnlock(
                        password: masterPassword,
                        masterPasswordUnlock: MasterPasswordUnlockData(
                            kdf: sdkKDF,
                            masterKeyWrappedUserKey: protectedUserKey,
                            salt: email
                        )
                    ),
                    upgradeToken: nil
                )
            )
            let encodedUserKey = try await client.crypto().getUserEncryptionKey()
            guard let userKey = Data(base64Encoded: encodedUserKey), userKey.count == 64 else {
                throw VaultCryptoError.invalidUserKey
            }
            return userKey
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.sdkFailure(error.localizedDescription)
        }
    }

    private func makeClient() -> Client {
        BitwardenSDKClientFactory.make()
    }

    private func sdkKDF(_ configuration: KDFConfiguration) throws -> Kdf {
        guard configuration.iterations > 0,
              let iterations = UInt32(exactly: configuration.iterations) else {
            throw VaultCryptoError.invalidKDFParameters
        }
        switch configuration.type {
        case .pbkdf2SHA256:
            return .pbkdf2(iterations: iterations)
        case .argon2id:
            guard let memoryValue = configuration.memory,
                  let parallelismValue = configuration.parallelism,
                  memoryValue > 0,
                  parallelismValue > 0,
                  let memory = UInt32(exactly: memoryValue),
                  let parallelism = UInt32(exactly: parallelismValue) else {
                throw VaultCryptoError.invalidKDFParameters
            }
            return .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
        }
    }
}
