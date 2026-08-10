import AuthenticationServices
import BitwardenSdk
import Foundation

nonisolated enum AutoFillPasskeyError: LocalizedError {
    case unavailable
    case credentialNotFound
    case invalidCryptoContext
    case registrationRequiresMainApp
    case unsupportedAlgorithm
    case credentialAlreadyExists
    case registrationNotSaved

    var errorDescription: String? {
        switch self {
        case .unavailable: "This passkey is unavailable. Open Vaultwarden and sync again."
        case .credentialNotFound: "The requested passkey was not found in the synced vault."
        case .invalidCryptoContext: "The passkey crypto state is incomplete. Sign in and sync again."
        case .registrationRequiresMainApp:
            "Creating new passkeys is not available in this build yet. Existing Vaultwarden passkeys can be used."
        case .unsupportedAlgorithm:
            "This website requested a passkey algorithm that Vaultwarden does not support."
        case .credentialAlreadyExists:
            "A passkey for this account already exists in Vaultwarden."
        case .registrationNotSaved:
            "The new passkey could not be saved to Vaultwarden."
        }
    }
}

@available(iOS 17.0, *)
nonisolated struct AutoFillPasskeyRegistrationResult {
    let credential: ASPasskeyRegistrationCredential
    let passkey: AutoFillPasskeyRecord
    let cipher: AutoFillPasskeyCipherRecord
    let writeSession: AutoFillWriteSession
}

@available(iOS 17.0, *)
nonisolated enum AutoFillPasskeySupport {
    static func register(
        request: ASPasskeyCredentialRequest,
        unlockedVault: AutoFillUnlockedVault
    ) async throws -> AutoFillPasskeyRegistrationResult {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            throw AutoFillPasskeyError.credentialNotFound
        }
        let payload = unlockedVault.payload
        guard let context = payload.cryptoContext,
              let writeSession = payload.writeSession else {
            throw AutoFillPasskeyError.invalidCryptoContext
        }

        let parameters = supportedParameters(request.supportedAlgorithms)
        guard !parameters.isEmpty else { throw AutoFillPasskeyError.unsupportedAlgorithm }

        let client = try await makeClient(context: context, userKey: unlockedVault.userKey)
        let store = PasskeyRegistrationStore(
            ciphers: payload.passkeyCiphers ?? [],
            passkeys: payload.passkeys ?? [],
            writeSession: writeSession,
            accountReference: payload.accountReference
        )
        let userInterface = PasskeyRegistrationUserInterface()
        let excluded = request.excludedCredentials?.map {
            PublicKeyCredentialDescriptor(ty: "public-key", id: $0.credentialID, transports: nil)
        }
        let result = try await client.platform().fido2()
            .authenticator(userInterface: userInterface, credentialStore: store)
            .makeCredential(request: MakeCredentialRequest(
                clientDataHash: request.clientDataHash,
                rp: PublicKeyCredentialRpEntity(
                    id: identity.relyingPartyIdentifier,
                    name: identity.relyingPartyIdentifier
                ),
                user: PublicKeyCredentialUserEntity(
                    id: identity.userHandle,
                    displayName: identity.userName,
                    name: identity.userName
                ),
                pubKeyCredParams: parameters,
                excludeList: excluded?.isEmpty == false ? excluded : nil,
                options: Options(rk: true, uv: uvPreference(request.userVerificationPreference)),
                extensions: nil
            ))

        guard let saved = await store.savedCredential() else {
            throw AutoFillPasskeyError.registrationNotSaved
        }
        let decryptedView = try await client.vault().ciphers().decrypt(cipher: saved.context.cipher)
        let cipher = AutoFillPasskeyCipherRecord(
            view: decryptedView,
            identifier: saved.identifier
        )
        return AutoFillPasskeyRegistrationResult(
            credential: ASPasskeyRegistrationCredential(
                relyingParty: identity.relyingPartyIdentifier,
                clientDataHash: request.clientDataHash,
                credentialID: result.credentialId,
                attestationObject: result.attestationObject
            ),
            passkey: AutoFillPasskeyRecord(
                cipherID: saved.identifier,
                relyingPartyIdentifier: identity.relyingPartyIdentifier,
                userName: identity.userName,
                credentialID: result.credentialId,
                userHandle: identity.userHandle,
                hasCounter: false
            ),
            cipher: cipher,
            writeSession: saved.writeSession
        )
    }

    static func assertion(
        request: ASPasskeyCredentialRequest,
        unlockedVault: AutoFillUnlockedVault
    ) async throws -> ASPasskeyAssertionCredential {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            throw AutoFillPasskeyError.credentialNotFound
        }
        guard let passkeys = unlockedVault.payload.passkeys else {
            throw AutoFillPasskeyError.invalidCryptoContext
        }
        let selectedCipherID = identity.recordIdentifier
            ?? passkeys.first(where: { $0.credentialID == identity.credentialID })?.cipherID
        guard let selectedCipherID else { throw AutoFillPasskeyError.credentialNotFound }

        return try await assertion(
            relyingPartyIdentifier: identity.relyingPartyIdentifier,
            clientDataHash: request.clientDataHash,
            allowedCredentialIDs: [identity.credentialID],
            userVerificationPreference: request.userVerificationPreference,
            selectedCipherID: selectedCipherID,
            unlockedVault: unlockedVault
        )
    }

    static func assertion(
        requestParameters: ASPasskeyCredentialRequestParameters,
        selectedPasskey: AutoFillPasskeyRecord,
        unlockedVault: AutoFillUnlockedVault
    ) async throws -> ASPasskeyAssertionCredential {
        try await assertion(
            relyingPartyIdentifier: requestParameters.relyingPartyIdentifier,
            clientDataHash: requestParameters.clientDataHash,
            allowedCredentialIDs: requestParameters.allowedCredentials.isEmpty
                ? [selectedPasskey.credentialID]
                : requestParameters.allowedCredentials,
            userVerificationPreference: requestParameters.userVerificationPreference,
            selectedCipherID: selectedPasskey.cipherID,
            unlockedVault: unlockedVault
        )
    }

    private static func assertion(
        relyingPartyIdentifier: String,
        clientDataHash: Data,
        allowedCredentialIDs: [Data],
        userVerificationPreference: ASAuthorizationPublicKeyCredentialUserVerificationPreference,
        selectedCipherID: String,
        unlockedVault: AutoFillUnlockedVault
    ) async throws -> ASPasskeyAssertionCredential {
        let payload = unlockedVault.payload
        guard let context = payload.cryptoContext,
              let ciphers = payload.passkeyCiphers,
              let passkeys = payload.passkeys else {
            throw AutoFillPasskeyError.invalidCryptoContext
        }

        let client = try await makeClient(context: context, userKey: unlockedVault.userKey)
        let store = PasskeyStore(ciphers: ciphers, passkeys: passkeys)
        let userInterface = PasskeyUserInterface(selectedCipherID: selectedCipherID)
        let result = try await client.platform().fido2()
            .authenticator(userInterface: userInterface, credentialStore: store)
            .getAssertion(request: GetAssertionRequest(
                rpId: relyingPartyIdentifier,
                clientDataHash: clientDataHash,
                allowList: allowedCredentialIDs.map {
                    PublicKeyCredentialDescriptor(ty: "public-key", id: $0, transports: nil)
                },
                options: Options(
                    rk: false,
                    uv: uvPreference(userVerificationPreference)
                ),
                extensions: nil
            ))

        return ASPasskeyAssertionCredential(
            userHandle: result.userHandle,
            relyingParty: relyingPartyIdentifier,
            signature: result.signature,
            clientDataHash: clientDataHash,
            authenticatorData: result.authenticatorData,
            credentialID: result.credentialId
        )
    }

    static func makeClient(
        context: AutoFillCryptoContext,
        userKey: Data
    ) async throws -> Client {
        guard userKey.count == 64,
              context.iterations > 0,
              let iterations = UInt32(exactly: context.iterations) else {
            throw AutoFillPasskeyError.invalidCryptoContext
        }
        let kdf: Kdf
        switch context.kdfType {
        case 0:
            kdf = .pbkdf2(iterations: iterations)
        case 1:
            guard let memory = context.memory.flatMap(UInt32.init(exactly:)),
                  let parallelism = context.parallelism.flatMap(UInt32.init(exactly:)),
                  memory > 0, parallelism > 0 else {
                throw AutoFillPasskeyError.invalidCryptoContext
            }
            kdf = .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
        default:
            throw AutoFillPasskeyError.invalidCryptoContext
        }
        let accountState: WrappedAccountCryptographicState
        if let signedPublicKey = context.signedPublicKey,
           let signingKey = context.signingKey,
           let securityState = context.securityState {
            accountState = .v2(
                privateKey: context.privateKey,
                signedPublicKey: signedPublicKey,
                signingKey: signingKey,
                securityState: securityState
            )
        } else {
            accountState = .v1(privateKey: context.privateKey)
        }

        let client = Client(tokenProvider: PasskeyTokenProvider(), settings: nil)
        client.platform().state().registerClientManagedRepositories(repositories: Repositories(
            cipher: nil,
            folder: nil,
            userKeyState: nil,
            localUserDataKeyState: PasskeyLocalUserDataRepository(),
            ephemeralPinEnvelopeState: nil,
            organizationSharedKey: nil,
            send: nil
        ))
        try await client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
            userId: context.userID,
            kdfParams: kdf,
            email: context.email,
            accountCryptographicState: accountState,
            method: .decryptedKey(decryptedUserKey: userKey.base64EncodedString()),
            upgradeToken: nil
        ))
        if !context.organizationKeys.isEmpty {
            try await client.crypto().initializeOrgCrypto(
                req: InitOrgCryptoRequest(organizationKeys: context.organizationKeys)
            )
        }
        return client
    }

    private static func supportedParameters(
        _ algorithms: [ASCOSEAlgorithmIdentifier]
    ) -> [PublicKeyCredentialParameters] {
        if algorithms.isEmpty {
            return [
                PublicKeyCredentialParameters(ty: "public-key", alg: -7),
                PublicKeyCredentialParameters(ty: "public-key", alg: -257)
            ]
        }
        guard algorithms.contains(where: { $0.rawValue == -7 }) else { return [] }
        return [PublicKeyCredentialParameters(ty: "public-key", alg: -7)]
    }

    fileprivate static func uvPreference(
        _ value: ASAuthorizationPublicKeyCredentialUserVerificationPreference
    ) -> Uv {
        switch value {
        case .required: .required
        case .discouraged: .discouraged
        default: .preferred
        }
    }
}

nonisolated struct AutoFillNewLoginInput: Sendable {
    let name: String
    let username: String
    let password: String
    let uri: String
    let favorite: Bool
    let totpSecret: String
    let folderID: String?
    let notes: String
    let customFields: [AutoFillNewCustomField]
}

nonisolated enum AutoFillNewCustomFieldType: UInt8, CaseIterable, Identifiable, Sendable {
    case text = 0
    case hidden = 1
    case boolean = 2
    case linked = 3

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .hidden: "Hidden"
        case .boolean: "Boolean"
        case .linked: "Linked"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .hidden: "eye.slash.fill"
        case .boolean: "checkmark.square.fill"
        case .linked: "link"
        }
    }
}

nonisolated struct AutoFillNewCustomField: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""
    var type: AutoFillNewCustomFieldType = .text
}

nonisolated struct AutoFillCreateLoginResult: Sendable {
    let record: AutoFillCredentialRecord
    let writeSession: AutoFillWriteSession
}

nonisolated struct AutoFillEncryptedCipherSaveResult: Sendable {
    let identifier: String
    let writeSession: AutoFillWriteSession
}

nonisolated enum AutoFillCreateLoginError: LocalizedError {
    case unavailable
    case invalidInput
    case sessionExpired
    case invalidResponse
    case serverRejected(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Creating passwords is unavailable. Open Vaultwarden and sync once."
        case .invalidInput: "Enter a name and password before saving."
        case .sessionExpired: "Your session expired. Open Vaultwarden and sync before creating a password."
        case .invalidResponse: "Vaultwarden returned an invalid response."
        case let .serverRejected(status, message):
            message ?? "Vaultwarden rejected the new password (HTTP \(status))."
        }
    }
}

@available(iOS 17.0, *)
nonisolated enum AutoFillCreateLoginSupport {
    static func create(
        input: AutoFillNewLoginInput,
        unlockedVault: AutoFillUnlockedVault
    ) async throws -> AutoFillCreateLoginResult {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = input.password
        guard !name.isEmpty, !password.isEmpty else {
            throw AutoFillCreateLoginError.invalidInput
        }
        guard let cryptoContext = unlockedVault.payload.cryptoContext,
              let writeSession = unlockedVault.payload.writeSession else {
            throw AutoFillCreateLoginError.unavailable
        }

        let client = try await AutoFillPasskeySupport.makeClient(
            context: cryptoContext,
            userKey: unlockedVault.userKey
        )
        let now = Date()
        let uri = input.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let customFields = input.customFields.compactMap { field -> FieldView? in
            guard !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let sdkType: BitwardenSdk.FieldType = switch field.type {
            case .text: .text
            case .hidden: .hidden
            case .boolean: .boolean
            case .linked: .linked
            }
            let linkedID: UInt32? = field.type == .linked
                ? (field.value == "password" ? 101 : 100)
                : nil
            return FieldView(
                name: field.name.nilIfBlank,
                value: field.type == .linked ? nil : field.value,
                type: sdkType,
                linkedId: linkedID
            )
        }
        let view = CipherView(
            id: nil,
            organizationId: nil,
            folderId: input.folderID,
            collectionIds: [],
            key: nil,
            name: name,
            notes: input.notes.nilIfBlank,
            type: .login,
            login: LoginView(
                username: input.username.nilIfBlank,
                password: password,
                passwordRevisionDate: now,
                uris: uri.isEmpty ? nil : [LoginUriView(uri: uri, match: nil, uriChecksum: nil)],
                totp: input.totpSecret.nilIfBlank,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            identity: nil,
            card: nil,
            secureNote: nil,
            sshKey: nil,
            bankAccount: nil,
            driversLicense: nil,
            passport: nil,
            favorite: input.favorite,
            reprompt: .none,
            organizationUseTotp: false,
            edit: true,
            permissions: nil,
            viewPassword: true,
            localData: nil,
            attachments: nil,
            attachmentDecryptionFailures: nil,
            fields: customFields.isEmpty ? nil : customFields,
            passwordHistory: nil,
            creationDate: now,
            deletedDate: nil,
            revisionDate: now,
            archivedDate: nil
        )
        let encryptionContext = try await client.vault().ciphers().encrypt(cipherView: view)
        let saved = try await saveEncryptedCipher(
            encryptionContext,
            writeSession: writeSession,
            accountReference: unlockedVault.payload.accountReference
        )

        return AutoFillCreateLoginResult(
            record: AutoFillCredentialRecord(
                id: saved.identifier,
                name: name,
                username: input.username,
                password: password,
                serviceIdentifier: normalizedServiceIdentifier(uri),
                totpSecret: input.totpSecret.nilIfBlank,
                uriRules: uri.isEmpty ? nil : [AutoFillURIRule(uri: uri, match: nil)]
            ),
            writeSession: saved.writeSession
        )
    }

    static func saveEncryptedCipher(
        _ encryptionContext: EncryptionContext,
        writeSession initialWriteSession: AutoFillWriteSession,
        accountReference: String
    ) async throws -> AutoFillEncryptedCipherSaveResult {
        var writeSession = initialWriteSession
        if writeSession.expiresAt <= Date().addingTimeInterval(30) {
            writeSession = try await refresh(
                writeSession,
                accountReference: accountReference
            )
        }
        let body = try encoder.encode(AutoFillCipherWriteRequest(encryptionContext))

        var response = try await createRequest(body: body, session: writeSession)
        if response.1.statusCode == 401 {
            writeSession = try await refresh(
                writeSession,
                accountReference: accountReference
            )
            response = try await createRequest(body: body, session: writeSession)
        }
        try validate(response.1, data: response.0)

        let identifier = responseIdentifier(response.0) ?? UUID().uuidString.lowercased()
        return AutoFillEncryptedCipherSaveResult(
            identifier: identifier,
            writeSession: writeSession
        )
    }

    private static func createRequest(
        body: Data,
        session: AutoFillWriteSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint(session.serverURL, path: "api/ciphers"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("\(session.tokenType) \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vaultwardenApp/iOS-AutoFill", forHTTPHeaderField: "User-Agent")
        return try await data(for: request)
    }

    private static func refresh(
        _ session: AutoFillWriteSession,
        accountReference: String
    ) async throws -> AutoFillWriteSession {
        guard let refreshToken = session.refreshToken else {
            throw AutoFillCreateLoginError.sessionExpired
        }
        var request = URLRequest(url: endpoint(session.serverURL, path: "identity/connect/token"))
        request.httpMethod = "POST"
        request.httpBody = formData([
            ("grant_type", "refresh_token"),
            ("client_id", "mobile"),
            ("refresh_token", refreshToken)
        ])
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vaultwardenApp/iOS-AutoFill", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        let token = try JSONDecoder().decode(AutoFillRefreshTokenResponse.self, from: data)
        let refreshed = AutoFillWriteSession(
            serverURL: session.serverURL,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            tokenType: token.tokenType,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
        try AutoFillSharedVault.saveWriteSessionUpdate(refreshed, reference: accountReference)
        return refreshed
    }

    private static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AutoFillCreateLoginError.invalidResponse
        }
        return (data, response)
    }

    private static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }
                .flatMap { ($0["message"] ?? $0["error_description"] ?? $0["error"]) as? String }
            throw AutoFillCreateLoginError.serverRejected(response.statusCode, message)
        }
    }

    private static func endpoint(_ baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) {
            $0.appendingPathComponent(String($1))
        }
    }

    private static func responseIdentifier(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["id"] ?? object["Id"] ?? object["ID"]) as? String
    }

    private static func normalizedServiceIdentifier(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        if let host = URL(string: value)?.host?.lowercased() { return host }
        return URL(string: "https://\(value)")?.host?.lowercased()
    }

    private static func formData(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        let body = values.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: "%20", with: "+") ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

private nonisolated struct AutoFillRefreshTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

private nonisolated struct AutoFillCipherWriteRequest: Encodable {
    let archivedDate: Date?
    let attachments2: [String: String]?
    let card: String?
    let data: String?
    let encryptedFor: String?
    let favorite: Bool
    let fields: [AutoFillFieldWriteRequest]?
    let folderId: String?
    let identity: String?
    let lastKnownRevisionDate: Date
    let login: AutoFillLoginWriteRequest?
    let key: String?
    let name: String?
    let notes: String?
    let organizationId: String?
    let passwordHistory: [String]?
    let reprompt: UInt8
    let secureNote: String?
    let sshKey: String?
    let type: UInt8

    init(_ context: EncryptionContext) {
        let cipher = context.cipher
        archivedDate = cipher.archivedDate
        attachments2 = nil
        card = nil
        data = cipher.data
        encryptedFor = context.encryptedFor
        favorite = cipher.favorite
        fields = cipher.fields?.map(AutoFillFieldWriteRequest.init)
        folderId = cipher.folderId
        identity = nil
        lastKnownRevisionDate = cipher.revisionDate
        login = cipher.login.map(AutoFillLoginWriteRequest.init)
        key = cipher.key
        name = cipher.name
        notes = cipher.notes
        organizationId = cipher.organizationId
        passwordHistory = nil
        reprompt = cipher.reprompt.rawValue
        secureNote = nil
        sshKey = nil
        type = cipher.type.rawValue
    }
}

private nonisolated struct AutoFillFieldWriteRequest: Encodable {
    let name: String?
    let value: String?
    let type: UInt8
    let linkedId: UInt32?

    init(_ field: Field) {
        name = field.name
        value = field.value
        type = field.type.rawValue
        linkedId = field.linkedId
    }
}

private nonisolated struct AutoFillLoginWriteRequest: Encodable {
    let username: String?
    let password: String?
    let passwordRevisionDate: Date?
    let uris: [AutoFillLoginURIWriteRequest]?
    let totp: String?
    let autofillOnPageLoad: Bool?
    let fido2Credentials: [AutoFillFido2CredentialWriteRequest]?

    init(_ value: Login) {
        username = value.username
        password = value.password
        passwordRevisionDate = value.passwordRevisionDate
        uris = value.uris?.map(AutoFillLoginURIWriteRequest.init)
        totp = value.totp
        autofillOnPageLoad = value.autofillOnPageLoad
        fido2Credentials = value.fido2Credentials?.map(AutoFillFido2CredentialWriteRequest.init)
    }
}

private nonisolated struct AutoFillFido2CredentialWriteRequest: Encodable {
    let credentialId: String
    let keyType: String
    let keyAlgorithm: String
    let keyCurve: String
    let keyValue: String
    let rpId: String
    let userHandle: String?
    let userName: String?
    let counter: String
    let rpName: String?
    let userDisplayName: String?
    let discoverable: String
    let creationDate: Date

    init(_ value: Fido2Credential) {
        credentialId = value.credentialId
        keyType = value.keyType
        keyAlgorithm = value.keyAlgorithm
        keyCurve = value.keyCurve
        keyValue = value.keyValue
        rpId = value.rpId
        userHandle = value.userHandle
        userName = value.userName
        counter = value.counter
        rpName = value.rpName
        userDisplayName = value.userDisplayName
        discoverable = value.discoverable
        creationDate = value.creationDate
    }
}

private nonisolated struct AutoFillLoginURIWriteRequest: Encodable {
    let uri: String?
    let match: UInt8?
    let uriChecksum: String?

    init(_ value: LoginUri) {
        uri = value.uri
        match = value.match?.rawValue
        uriChecksum = value.uriChecksum
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

@available(iOS 17.0, *)
private nonisolated actor PasskeyRegistrationStore: Fido2CredentialStore {
    struct SavedCredential: Sendable {
        let context: EncryptionContext
        let identifier: String
        let writeSession: AutoFillWriteSession
    }

    private let ciphers: [String: CipherView]
    private let passkeys: [AutoFillPasskeyRecord]
    private let initialWriteSession: AutoFillWriteSession
    private let accountReference: String
    private var saved: SavedCredential?

    init(
        ciphers: [AutoFillPasskeyCipherRecord],
        passkeys: [AutoFillPasskeyRecord],
        writeSession: AutoFillWriteSession,
        accountReference: String
    ) {
        self.ciphers = Dictionary(uniqueKeysWithValues: ciphers.map { ($0.id, $0.sdkView) })
        self.passkeys = passkeys
        initialWriteSession = writeSession
        self.accountReference = accountReference
    }

    func findCredentials(ids: [Data]?, ripId: String, userHandle: Data?) async throws -> [CipherView] {
        let cipherIDs = Set(AutoFillPasskeyMatcher.matching(
            passkeys,
            relyingPartyIdentifier: ripId,
            allowedCredentialIDs: ids,
            userHandle: userHandle
        ).map(\.cipherID))
        return cipherIDs.compactMap { ciphers[$0] }
    }

    func allCredentials() async throws -> [CipherListView] { [] }

    func saveCredential(cred: EncryptionContext) async throws {
        let result = try await AutoFillCreateLoginSupport.saveEncryptedCipher(
            cred,
            writeSession: initialWriteSession,
            accountReference: accountReference
        )
        saved = SavedCredential(
            context: cred,
            identifier: result.identifier,
            writeSession: result.writeSession
        )
    }

    func savedCredential() -> SavedCredential? { saved }
}

@available(iOS 17.0, *)
private nonisolated final class PasskeyRegistrationUserInterface: Fido2UserInterface, @unchecked Sendable {
    func checkUser(options: CheckUserOptions, hint: UiHint) async throws -> CheckUserResult {
        if case .informExcludedCredentialFound = hint {
            throw AutoFillPasskeyError.credentialAlreadyExists
        }
        return CheckUserResult(userPresent: true, userVerified: true)
    }

    func pickCredentialForAuthentication(
        availableCredentials: [CipherView]
    ) async throws -> CipherViewWrapper {
        throw AutoFillPasskeyError.credentialNotFound
    }

    func checkUserAndPickCredentialForCreation(
        options: CheckUserOptions,
        newCredential: Fido2CredentialNewView
    ) async throws -> CheckUserAndPickCredentialForCreationResult {
        let now = Date()
        let cipher = CipherView(
            id: nil,
            organizationId: nil,
            folderId: nil,
            collectionIds: [],
            key: nil,
            name: newCredential.rpName ?? newCredential.rpId,
            notes: nil,
            type: .login,
            login: LoginView(
                username: newCredential.userName ?? "",
                password: nil,
                passwordRevisionDate: nil,
                uris: [LoginUriView(uri: newCredential.rpId, match: nil, uriChecksum: nil)],
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            identity: nil,
            card: nil,
            secureNote: nil,
            sshKey: nil,
            bankAccount: nil,
            driversLicense: nil,
            passport: nil,
            favorite: false,
            reprompt: .none,
            organizationUseTotp: false,
            edit: false,
            permissions: nil,
            viewPassword: true,
            localData: nil,
            attachments: nil,
            attachmentDecryptionFailures: nil,
            fields: nil,
            passwordHistory: nil,
            creationDate: now,
            deletedDate: nil,
            revisionDate: now,
            archivedDate: nil
        )
        return CheckUserAndPickCredentialForCreationResult(
            cipher: CipherViewWrapper(cipher: cipher),
            checkUserResult: CheckUserResult(userPresent: true, userVerified: true)
        )
    }

    func isVerificationEnabled() -> Bool { true }
}

@available(iOS 17.0, *)
private nonisolated final class PasskeyStore: Fido2CredentialStore, @unchecked Sendable {
    private let ciphers: [String: CipherView]
    private let passkeys: [AutoFillPasskeyRecord]

    init(ciphers: [AutoFillPasskeyCipherRecord], passkeys: [AutoFillPasskeyRecord]) {
        self.ciphers = Dictionary(uniqueKeysWithValues: ciphers.map { ($0.id, $0.sdkView) })
        self.passkeys = passkeys
    }

    func findCredentials(ids: [Data]?, ripId: String, userHandle: Data?) async throws -> [CipherView] {
        let cipherIDs = Set(AutoFillPasskeyMatcher.matching(
            passkeys,
            relyingPartyIdentifier: ripId,
            allowedCredentialIDs: ids,
            userHandle: userHandle
        ).map(\.cipherID))
        return cipherIDs.compactMap { ciphers[$0] }
    }

    func allCredentials() async throws -> [CipherListView] { [] }

    func saveCredential(cred: EncryptionContext) async throws {
        throw AutoFillPasskeyError.registrationRequiresMainApp
    }
}

nonisolated enum AutoFillPasskeyMatcher {
    static func matching(
        _ records: [AutoFillPasskeyRecord],
        relyingPartyIdentifier: String,
        allowedCredentialIDs: [Data]?,
        userHandle: Data?
    ) -> [AutoFillPasskeyRecord] {
        records.filter { passkey in
            passkey.relyingPartyIdentifier == relyingPartyIdentifier
                && (allowedCredentialIDs == nil || allowedCredentialIDs?.contains(passkey.credentialID) == true)
                && (userHandle == nil || userHandle == passkey.userHandle)
        }
    }
}

@available(iOS 17.0, *)
private nonisolated final class PasskeyUserInterface: Fido2UserInterface, @unchecked Sendable {
    private let selectedCipherID: String

    init(selectedCipherID: String) {
        self.selectedCipherID = selectedCipherID
    }

    func checkUser(options: CheckUserOptions, hint: UiHint) async throws -> CheckUserResult {
        // AutoFillSharedVault has already completed device-owner authentication for this request.
        CheckUserResult(userPresent: true, userVerified: true)
    }

    func pickCredentialForAuthentication(
        availableCredentials: [CipherView]
    ) async throws -> CipherViewWrapper {
        guard let selected = availableCredentials.first(where: { $0.id == selectedCipherID })
            ?? availableCredentials.first else {
            throw AutoFillPasskeyError.credentialNotFound
        }
        return CipherViewWrapper(cipher: selected)
    }

    func checkUserAndPickCredentialForCreation(
        options: CheckUserOptions,
        newCredential: Fido2CredentialNewView
    ) async throws -> CheckUserAndPickCredentialForCreationResult {
        throw AutoFillPasskeyError.registrationRequiresMainApp
    }

    func isVerificationEnabled() -> Bool { true }
}

private nonisolated final class PasskeyTokenProvider: ClientManagedTokens, @unchecked Sendable {
    func getAccessToken() async -> String? { nil }
}

private nonisolated actor PasskeyLocalUserDataRepository: LocalUserDataKeyStateRepository {
    private var values: [String: LocalUserDataKeyState] = [:]

    func get(id: String) async throws -> LocalUserDataKeyState? { values[id] }
    func list() async throws -> [LocalUserDataKeyState] { Array(values.values) }
    func set(id: String, value: LocalUserDataKeyState) async throws { values[id] = value }
    func setBulk(values newValues: [String: LocalUserDataKeyState]) async throws {
        values.merge(newValues) { _, new in new }
    }
    func remove(id: String) async throws { values.removeValue(forKey: id) }
    func removeBulk(keys: [String]) async throws { keys.forEach { values.removeValue(forKey: $0) } }
    func removeAll() async throws { values.removeAll(keepingCapacity: false) }
    func has(id: String) async throws -> Bool { values[id] != nil }
}
