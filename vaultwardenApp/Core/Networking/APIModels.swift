import Foundation

nonisolated enum BitwardenJSONDecoder {
    static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let key = codingPath.last?.stringValue ?? ""
            let normalized: String
            if key.contains("_") {
                normalized = key.lowercased()
                    .split(separator: "_")
                    .enumerated()
                    .map { index, component in
                        index == 0 ? String(component) : component.capitalized
                    }
                    .joined()
            } else {
                normalized = key.prefix(1).lowercased() + key.dropFirst()
            }
            return BitwardenCodingKey(stringValue: normalized)
        }
        return decoder
    }
}

private struct BitwardenCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

nonisolated enum KDFType: Int, Codable, Sendable {
    case pbkdf2SHA256 = 0
    case argon2id = 1
}

nonisolated struct KDFConfiguration: Codable, Equatable, Sendable {
    let type: KDFType
    let iterations: Int
    let memory: Int?
    let parallelism: Int?
}

nonisolated struct PreLoginRequestDTO: Encodable {
    let email: String
}

nonisolated struct PreLoginResponseDTO: Decodable {
    let kdf: KDFType
    let kdfIterations: Int
    let kdfMemory: Int?
    let kdfParallelism: Int?

    var configuration: KDFConfiguration {
        KDFConfiguration(
            type: kdf,
            iterations: kdfIterations,
            memory: kdfMemory,
            parallelism: kdfParallelism
        )
    }
}

nonisolated struct ServerConfigDTO: Decodable {
    let version: String?
}

nonisolated struct IdentityTokenResponseDTO: Decodable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String
    let refreshToken: String?
    let protectedUserKey: String?
    let protectedPrivateKey: String?
    let accountKeys: AccountKeysDTO?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresIn
        case tokenType
        case refreshToken
        case protectedUserKey = "key"
        case protectedPrivateKey = "privateKey"
        case accountKeys
    }

    var userID: String? {
        AccessTokenClaimsParser.userID(from: accessToken)
    }
}

nonisolated enum AccessTokenClaimsParser {
    private struct Claims: Decodable {
        let sub: String
    }

    static func userID(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              !claims.sub.isEmpty else {
            return nil
        }
        return claims.sub
    }
}

nonisolated struct AccountKeysDTO: Decodable, Sendable {
    let publicKeyEncryptionKeyPair: PublicKeyEncryptionKeyPairDTO
    let signatureKeyPair: SignatureKeyPairDTO?
    let securityState: SecurityStateDTO?

}

nonisolated struct PublicKeyEncryptionKeyPairDTO: Decodable, Sendable {
    let wrappedPrivateKey: String
    let signedPublicKey: String?

}

nonisolated struct SignatureKeyPairDTO: Decodable, Sendable {
    let wrappedSigningKey: String

}

nonisolated struct SecurityStateDTO: Decodable, Sendable {
    let securityState: String?

}

nonisolated struct WrappedAccountKeys: Codable, Sendable {
    let privateKey: String
    let signedPublicKey: String?
    let signingKey: String?
    let securityState: String?
}

nonisolated struct IdentityErrorDTO: Decodable {
    let error: String?
    let errorDescription: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
    }
}

nonisolated struct PendingLoginRequestListDTO: Decodable, Sendable {
    let data: [PendingLoginRequestDTO]
}

nonisolated struct PendingLoginRequestDTO: Decodable, Sendable {
    let id: String
    let publicKey: String
    let requestDeviceType: String
    let requestIpAddress: String
    let creationDate: String
    let origin: String?
}

nonisolated struct LoginRequestResponseDTO: Encodable, Sendable {
    let deviceIdentifier: String
    let key: String
    let masterPasswordHash: String?
    let requestApproved: Bool
}
