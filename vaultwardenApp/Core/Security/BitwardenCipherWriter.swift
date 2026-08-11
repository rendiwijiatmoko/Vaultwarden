import BitwardenSdk
import Foundation

nonisolated enum BitwardenCipherWriter {
    static func encrypt(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials,
        organizationKeys: [String: String]
    ) async throws -> EncryptionContext {
        let client = try await initializedClient(
            email: email,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        return try await client.vault().ciphers().encrypt(
            cipherView: makeView(item: item, existing: existing?.view, folderID: folderID)
        )
    }

    static func initializedClient(
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials,
        organizationKeys: [String: String]
    ) async throws -> Client {
        guard userKey.count == 64,
              let accountKeys = credentials.accountKeys,
              let kdf = credentials.kdf else {
            throw VaultCryptoError.missingAccountKeys
        }
        let client = BitwardenSDKClientFactory.make()
        try await client.crypto().initializeUserCrypto(
            req: InitUserCryptoRequest(
                userId: credentials.userID,
                kdfParams: try kdf.sdkKDFForWrites,
                email: email,
                accountCryptographicState: accountKeys.sdkStateForWrites,
                method: .decryptedKey(decryptedUserKey: userKey.base64EncodedString()),
                upgradeToken: nil
            )
        )
        if !organizationKeys.isEmpty {
            try await client.crypto().initializeOrgCrypto(
                req: InitOrgCryptoRequest(organizationKeys: organizationKeys)
            )
        }
        return client
    }

    static func encryptTextSend(
        item: SendItem,
        password: String?,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> BitwardenSdk.Send {
        try await encryptTextSendPrepared(
            item: item,
            password: password,
            email: email,
            userKey: userKey,
            credentials: credentials
        ).send
    }

    static func encryptTextSendPrepared(
        item: SendItem,
        password: String?,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> (send: BitwardenSdk.Send, client: Client) {
        let client = try await initializedClient(
            email: email,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: [:]
        )
        let send = try client.sends().encrypt(
            send: makeNewSendView(item: item, password: password, fileName: nil)
        )
        return (send, client)
    }

    static func encryptFileSend(
        item: SendItem,
        password: String?,
        fileName: String,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> (send: BitwardenSdk.Send, client: Client) {
        let client = try await initializedClient(
            email: email,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: [:]
        )
        let send = try client.sends().encrypt(send: makeNewSendView(item: item, password: password, fileName: fileName))
        return (send, client)
    }

    private static func makeNewSendView(
        item: SendItem,
        password: String?,
        fileName: String?
    ) -> BitwardenSdk.SendView {
        BitwardenSdk.SendView(
            id: nil,
            accessId: nil,
            name: item.name,
            notes: nil,
            key: nil,
            newPassword: password?.nilIfEmpty,
            hasPassword: false,
            type: fileName == nil ? .text : .file,
            file: fileName.map { SendFileView(id: nil, fileName: $0, size: nil, sizeName: nil) },
            text: fileName == nil ? SendTextView(text: item.text, hidden: false) : nil,
            maxAccessCount: item.maximumAccessCount.flatMap(UInt32.init(exactly:)),
            accessCount: 0,
            disabled: item.isDisabled,
            hideEmail: false,
            revisionDate: Date(),
            deletionDate: item.deletesAt,
            expirationDate: item.expiresAt,
            emails: [],
            authType: password?.isEmpty == false ? .password : .none
        )
    }

    static func encryptUpdatedSend(
        item: SendItem,
        existing: BitwardenSdk.SendView,
        passwordUpdate: SendPasswordUpdate,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> BitwardenSdk.Send {
        let client = try await initializedClient(
            email: email,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: [:]
        )
        let newPassword: String? = if case let .set(value) = passwordUpdate { value.nilIfEmpty } else { nil }
        let authType: AuthType = switch passwordUpdate {
        case .preserve: existing.authType
        case .set: .password
        case .remove: .none
        }
        let view = BitwardenSdk.SendView(
            id: existing.id,
            accessId: existing.accessId,
            name: item.name,
            notes: existing.notes,
            key: existing.key,
            newPassword: newPassword,
            hasPassword: existing.hasPassword,
            type: existing.type,
            file: existing.file,
            text: existing.type == .text
                ? SendTextView(text: item.text, hidden: existing.text?.hidden ?? false)
                : nil,
            maxAccessCount: item.maximumAccessCount.flatMap(UInt32.init(exactly:)),
            accessCount: existing.accessCount,
            disabled: item.isDisabled,
            hideEmail: existing.hideEmail,
            revisionDate: existing.revisionDate,
            deletionDate: item.deletesAt,
            expirationDate: item.expiresAt,
            emails: existing.emails,
            authType: authType
        )
        return try client.sends().encrypt(send: view)
    }

    private static func makeView(item: VaultItem, existing: CipherView?, folderID: String?) -> CipherView {
        let now = Date()
        let existingLoginURIs = existing?.login?.uris ?? []
        let loginURIs = item.websiteURIs.enumerated().map { index, uri in
            LoginUriView(
                uri: uri,
                match: existingLoginURIs.indices.contains(index) ? existingLoginURIs[index].match : nil,
                uriChecksum: nil
            )
        }
        let login: LoginView? = item.type == .login ? LoginView(
            username: item.username.nilIfEmpty,
            password: item.password.nilIfEmpty,
            passwordRevisionDate: existing?.login?.password == item.password
                ? existing?.login?.passwordRevisionDate
                : now,
            uris: loginURIs.isEmpty ? nil : loginURIs,
            totp: item.totpSecret?.nilIfEmpty,
            autofillOnPageLoad: existing?.login?.autofillOnPageLoad,
            fido2Credentials: existing?.login?.fido2Credentials
        ) : nil
        let card: CardView? = item.type == .card ? CardView(
            cardholderName: item.card?.cardholderName.nilIfEmpty,
            expMonth: item.card?.expirationMonth.nilIfEmpty,
            expYear: item.card?.expirationYear.nilIfEmpty,
            code: item.card?.securityCode.nilIfEmpty,
            brand: item.card?.brand.nilIfEmpty,
            number: item.card?.number.nilIfEmpty
        ) : nil
        let identity: IdentityView? = item.type == .identity ? IdentityView(
            title: item.identity?.title.nilIfEmpty,
            firstName: item.identity?.firstName.nilIfEmpty,
            middleName: item.identity?.middleName.nilIfEmpty,
            lastName: item.identity?.lastName.nilIfEmpty,
            address1: item.identity?.address1.nilIfEmpty,
            address2: item.identity?.address2.nilIfEmpty,
            address3: nil,
            city: item.identity?.city.nilIfEmpty,
            state: item.identity?.state.nilIfEmpty,
            postalCode: item.identity?.postalCode.nilIfEmpty,
            country: item.identity?.country.nilIfEmpty,
            company: item.identity?.company.nilIfEmpty,
            email: item.identity?.email.nilIfEmpty,
            phone: item.identity?.phone.nilIfEmpty,
            ssn: item.identity?.socialSecurityNumber.nilIfEmpty,
            username: item.identity?.username.nilIfEmpty,
            passportNumber: item.identity?.passportNumber.nilIfEmpty,
            licenseNumber: item.identity?.licenseNumber.nilIfEmpty
        ) : nil
        let sshKey: SshKeyView? = item.type == .sshKey ? SshKeyView(
            privateKey: item.password,
            publicKey: item.username,
            fingerprint: item.notes
        ) : nil

        return CipherView(
            id: existing?.id,
            organizationId: existing?.organizationId,
            folderId: folderID,
            collectionIds: existing?.collectionIds ?? item.collectionIDs,
            key: existing?.key,
            name: item.name,
            notes: item.notes.nilIfEmpty,
            type: item.type.sdkTypeForWrites,
            login: login,
            identity: identity,
            card: card,
            secureNote: item.type == .secureNote ? SecureNoteView(type: .generic) : nil,
            sshKey: sshKey,
            bankAccount: nil,
            driversLicense: nil,
            passport: nil,
            favorite: item.isFavorite,
            reprompt: existing?.reprompt ?? .none,
            organizationUseTotp: existing?.organizationUseTotp ?? false,
            edit: existing?.edit ?? true,
            permissions: existing?.permissions,
            viewPassword: existing?.viewPassword ?? true,
            localData: existing?.localData,
            attachments: existing?.attachments,
            attachmentDecryptionFailures: existing?.attachmentDecryptionFailures,
            fields: item.customFields.map(\.sdkFieldForWrites),
            passwordHistory: existing?.passwordHistory,
            creationDate: existing?.creationDate ?? item.createdAt ?? now,
            deletedDate: item.deletedAt ?? existing?.deletedDate,
            revisionDate: existing?.revisionDate ?? now,
            archivedDate: item.archivedAt
        )
    }
}

nonisolated struct CipherWriteRequestDTO: Encodable {
    let archivedDate: Date?
    let attachments2: [String: AttachmentWriteDTO]?
    let card: CardWriteDTO?
    let data: String?
    let encryptedFor: String?
    let favorite: Bool
    let fields: [FieldWriteDTO]?
    let folderId: String?
    let identity: IdentityWriteDTO?
    let lastKnownRevisionDate: Date
    let login: LoginWriteDTO?
    let key: String?
    let name: String?
    let notes: String?
    let organizationId: String?
    let passwordHistory: [PasswordHistoryWriteDTO]?
    let reprompt: UInt8
    let secureNote: SecureNoteWriteDTO?
    let sshKey: SSHKeyWriteDTO?
    let type: UInt8

    init(context: EncryptionContext) {
        let cipher = context.cipher
        archivedDate = cipher.archivedDate
        attachments2 = cipher.attachments?.reduce(into: [:]) { result, attachment in
            guard let id = attachment.id else { return }
            result[id] = AttachmentWriteDTO(attachment)
        }
        card = cipher.card.map(CardWriteDTO.init)
        data = cipher.data
        encryptedFor = context.encryptedFor
        favorite = cipher.favorite
        fields = cipher.fields?.map(FieldWriteDTO.init)
        folderId = cipher.folderId
        identity = cipher.identity.map(IdentityWriteDTO.init)
        lastKnownRevisionDate = cipher.revisionDate
        login = cipher.login.map(LoginWriteDTO.init)
        key = cipher.key
        name = cipher.name
        notes = cipher.notes
        organizationId = cipher.organizationId
        passwordHistory = cipher.passwordHistory?.map(PasswordHistoryWriteDTO.init)
        reprompt = cipher.reprompt.rawValue
        secureNote = cipher.secureNote.map { SecureNoteWriteDTO(type: $0.type.rawValue) }
        sshKey = cipher.sshKey.map(SSHKeyWriteDTO.init)
        type = cipher.type.rawValue
    }
}

nonisolated struct FolderWriteRequestDTO: Encodable {
    let name: String
}

nonisolated struct SendWriteRequestDTO: Encodable {
    let authType: UInt8?
    let deletionDate: Date
    let disabled: Bool
    let emails: String?
    let expirationDate: Date?
    let file: SendFileWriteDTO?
    let fileLength: Int64?
    let hideEmail: Bool
    let key: String
    let maxAccessCount: Int32?
    let name: String
    let notes: String?
    let password: String?
    let text: SendTextWriteDTO?
    let type: UInt8

    init(
        _ send: BitwardenSdk.Send,
        fileLength: Int64? = nil,
        passwordOverride: String? = nil
    ) {
        authType = send.authType.rawValue
        deletionDate = send.deletionDate
        disabled = send.disabled
        emails = send.emails
        expirationDate = send.expirationDate
        file = send.file.map(SendFileWriteDTO.init)
        self.fileLength = fileLength
        hideEmail = send.hideEmail
        key = send.key
        maxAccessCount = send.maxAccessCount.flatMap(Int32.init(exactly:))
        name = send.name
        notes = send.notes
        password = passwordOverride ?? send.password
        text = send.text.map { SendTextWriteDTO(text: $0.text, hidden: $0.hidden) }
        type = send.type.rawValue
    }
}

nonisolated struct SendFileWriteDTO: Encodable {
    let id: String?
    let fileName: String
    let size: String?
    let sizeName: String?

    init(_ file: BitwardenSdk.SendFile) {
        id = file.id
        fileName = file.fileName
        size = file.size
        sizeName = file.sizeName
    }
}

nonisolated struct SendTextWriteDTO: Encodable {
    let text: String?
    let hidden: Bool
}

nonisolated struct AttachmentWriteDTO: Encodable {
    let fileName: String?
    let key: String?
    init(_ value: Attachment) { fileName = value.fileName; key = value.key }
}

nonisolated struct CardWriteDTO: Encodable {
    let cardholderName: String?
    let expMonth: String?
    let expYear: String?
    let code: String?
    let brand: String?
    let number: String?
    init(_ value: Card) {
        cardholderName = value.cardholderName; expMonth = value.expMonth; expYear = value.expYear
        code = value.code; brand = value.brand; number = value.number
    }
}

nonisolated struct IdentityWriteDTO: Encodable {
    let title: String?; let firstName: String?; let middleName: String?; let lastName: String?
    let address1: String?; let address2: String?; let address3: String?; let city: String?
    let state: String?; let postalCode: String?; let country: String?; let company: String?
    let email: String?; let phone: String?; let ssn: String?; let username: String?
    let passportNumber: String?; let licenseNumber: String?
    init(_ value: Identity) {
        title = value.title; firstName = value.firstName; middleName = value.middleName; lastName = value.lastName
        address1 = value.address1; address2 = value.address2; address3 = value.address3; city = value.city
        state = value.state; postalCode = value.postalCode; country = value.country; company = value.company
        email = value.email; phone = value.phone; ssn = value.ssn; username = value.username
        passportNumber = value.passportNumber; licenseNumber = value.licenseNumber
    }
}

nonisolated struct LoginWriteDTO: Encodable {
    let username: String?; let password: String?; let passwordRevisionDate: Date?
    let uris: [LoginURIWriteDTO]?; let totp: String?; let autofillOnPageLoad: Bool?
    let fido2Credentials: [Fido2WriteDTO]?
    init(_ value: Login) {
        username = value.username; password = value.password; passwordRevisionDate = value.passwordRevisionDate
        uris = value.uris?.map(LoginURIWriteDTO.init); totp = value.totp
        autofillOnPageLoad = value.autofillOnPageLoad
        fido2Credentials = value.fido2Credentials?.map(Fido2WriteDTO.init)
    }
}

nonisolated struct LoginURIWriteDTO: Encodable {
    let uri: String?; let match: UInt8?; let uriChecksum: String?
    init(_ value: LoginUri) { uri = value.uri; match = value.match?.rawValue; uriChecksum = value.uriChecksum }
}

nonisolated struct Fido2WriteDTO: Encodable {
    let credentialId: String; let keyType: String; let keyAlgorithm: String; let keyCurve: String
    let keyValue: String; let rpId: String; let userHandle: String?; let userName: String?
    let counter: String; let rpName: String?; let userDisplayName: String?; let discoverable: String
    let creationDate: Date
    init(_ value: Fido2Credential) {
        credentialId = value.credentialId; keyType = value.keyType; keyAlgorithm = value.keyAlgorithm
        keyCurve = value.keyCurve; keyValue = value.keyValue; rpId = value.rpId
        userHandle = value.userHandle; userName = value.userName; counter = value.counter
        rpName = value.rpName; userDisplayName = value.userDisplayName; discoverable = value.discoverable
        creationDate = value.creationDate
    }
}

nonisolated struct FieldWriteDTO: Encodable {
    let name: String?; let value: String?; let type: UInt8; let linkedId: UInt32?
    init(_ field: Field) { name = field.name; value = field.value; type = field.type.rawValue; linkedId = field.linkedId }
}

nonisolated struct PasswordHistoryWriteDTO: Encodable {
    let password: String; let lastUsedDate: Date
    init(_ value: PasswordHistory) { password = value.password; lastUsedDate = value.lastUsedDate }
}

nonisolated struct SecureNoteWriteDTO: Encodable { let type: UInt8 }

nonisolated struct SSHKeyWriteDTO: Encodable {
    let privateKey: String; let publicKey: String?; let keyFingerprint: String?
    init(_ value: SshKey) { privateKey = value.privateKey; publicKey = value.publicKey; keyFingerprint = value.fingerprint }
}

private extension VaultItemType {
    nonisolated var sdkTypeForWrites: BitwardenSdk.CipherType {
        switch self {
        case .login: .login
        case .secureNote: .secureNote
        case .card: .card
        case .identity: .identity
        case .sshKey: .sshKey
        }
    }
}

private extension VaultCustomField {
    nonisolated var sdkFieldForWrites: FieldView {
        let sdkType: BitwardenSdk.FieldType = switch type {
        case .text: .text
        case .hidden: .hidden
        case .boolean: .boolean
        case .linked: .linked
        }
        let linkedID: UInt32? = type == .linked ? (value == "password" ? 101 : 100) : nil
        return FieldView(name: name.nilIfEmpty, value: type == .linked ? nil : value, type: sdkType, linkedId: linkedID)
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension KDFConfiguration {
    nonisolated var sdkKDFForWrites: Kdf {
        get throws {
            guard iterations > 0, let iterations = UInt32(exactly: iterations) else {
                throw VaultCryptoError.invalidKDFParameters
            }
            switch type {
            case .pbkdf2SHA256: return .pbkdf2(iterations: iterations)
            case .argon2id:
                guard let memory, let parallelism,
                      let memory = UInt32(exactly: memory), let parallelism = UInt32(exactly: parallelism),
                      memory > 0, parallelism > 0 else { throw VaultCryptoError.invalidKDFParameters }
                return .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
            }
        }
    }
}

private extension WrappedAccountKeys {
    nonisolated var sdkStateForWrites: WrappedAccountCryptographicState {
        if let signedPublicKey, let signingKey, let securityState {
            return .v2(
                privateKey: privateKey,
                signedPublicKey: signedPublicKey,
                signingKey: signingKey,
                securityState: securityState
            )
        }
        return .v1(privateKey: privateKey)
    }
}
