import BitwardenSdk
import Foundation

nonisolated struct DecryptedVaultSnapshot: Sendable {
    let items: [VaultItem]
    let folders: [VaultFolder]
    let collections: [VaultCollection]
    let sends: [SendItem]
    let remoteCiphers: [UUID: RemoteCipherState]
    let folderIDsByName: [String: String]
    let remoteSends: [UUID: RemoteSendState]
    let organizationKeys: [String: String]
}

nonisolated struct RemoteCipherState: Sendable {
    let view: CipherView

    var canEdit: Bool { view.edit }
    var canViewPassword: Bool { view.viewPassword }
}

nonisolated struct RemoteSendState: Sendable {
    let encrypted: BitwardenSdk.Send
    let view: BitwardenSdk.SendView
}

nonisolated protocol VaultPayloadDecoder: Sendable {
    func decode(
        payload: Data,
        serverURL: URL,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> DecryptedVaultSnapshot
}

nonisolated enum VaultPayloadDecoderError: LocalizedError {
    case invalidSyncPayload(details: String)
    case incompleteCryptoState
    case vaultItemsCouldNotBeDecrypted

    var errorDescription: String? {
        switch self {
        case let .invalidSyncPayload(details):
            "The server sync payload could not be decoded (\(details))."
        case .incompleteCryptoState: "The local account crypto state is incomplete. Please sign in again."
        case .vaultItemsCouldNotBeDecrypted:
            "Vault data was received, but none of its items could be decrypted. Please sign in again."
        }
    }
}

nonisolated struct BitwardenVaultPayloadDecoder: VaultPayloadDecoder {
    func decode(
        payload: Data,
        serverURL: URL,
        email: String,
        userKey: Data,
        credentials: StoredSessionCredentials
    ) async throws -> DecryptedVaultSnapshot {
        guard userKey.count == 64 else { throw VaultCryptoError.invalidUserKey }
        guard let accountKeys = credentials.accountKeys,
              let kdf = credentials.kdf else {
            throw VaultPayloadDecoderError.incompleteCryptoState
        }
        let sync: SyncResponseDTO
        do {
            sync = try BitwardenJSONDecoder.make().decode(SyncResponseDTO.self, from: payload)
        } catch {
            let details = decodingDetails(error)
            SecureLog.failure("Vault payload decoding", error: error, logger: SecureLog.crypto)
            throw VaultPayloadDecoderError.invalidSyncPayload(details: details)
        }

        let client = BitwardenSDKClientFactory.make()
        try await initializeClient(
            client,
            email: email,
            userID: sync.profile?.id,
            userKey: userKey,
            kdf: kdf,
            accountKeys: accountKeys,
            organizations: sync.profile?.organizations ?? []
        )

        var folderNames: [String: String] = [:]
        var folderIDsByName: [String: String] = [:]
        var folders: [VaultFolder] = []
        for folder in sync.folders {
            guard let revisionDate = ServerDateParser.parse(folder.revisionDate) else { continue }
            do {
                let view = try client.vault().folders().decrypt(
                    folder: Folder(id: folder.id, name: folder.name, revisionDate: revisionDate)
                )
                folderNames[folder.id] = view.name
                folderIDsByName[view.name] = folder.id
                folders.append(VaultFolder(id: UUID(uuidString: folder.id) ?? UUID(), name: view.name))
            } catch {
                continue
            }
        }

        let organizationNames = Dictionary(
            uniqueKeysWithValues: (sync.profile?.organizations ?? []).map {
                ($0.id, $0.name ?? "Organization")
            }
        )
        var collections: [VaultCollection] = []
        for collection in sync.collections {
            do {
                let view = try client.vault().collections().decrypt(collection: collection.sdkCollection)
                collections.append(
                    VaultCollection(
                        id: collection.id,
                        name: view.name,
                        organization: organizationNames[collection.organizationId] ?? "Shared Vault",
                        isReadOnly: view.readOnly,
                        hidesPasswords: view.hidePasswords
                    )
                )
            } catch {
                continue
            }
        }
        var items: [VaultItem] = []
        var remoteCiphers: [UUID: RemoteCipherState] = [:]
        var cipherFailures = 0
        for cipherDTO in sync.ciphers {
            guard let cipher = cipherDTO.sdkCipher else {
                cipherFailures += 1
                continue
            }
            do {
                let view = try await client.vault().ciphers().decrypt(cipher: cipher)
                let item = map(
                    view,
                    folderName: view.folderId.flatMap { folderNames[$0] },
                    organizationName: view.organizationId.flatMap { organizationNames[$0] },
                    collectionIDs: view.collectionIds
                )
                items.append(item)
                remoteCiphers[item.id] = RemoteCipherState(view: view)
            } catch {
                cipherFailures += 1
                continue
            }
        }
        if !sync.ciphers.isEmpty, items.isEmpty, cipherFailures == sync.ciphers.count {
            throw VaultPayloadDecoderError.vaultItemsCouldNotBeDecrypted
        }
        var sends: [SendItem] = []
        var remoteSends: [UUID: RemoteSendState] = [:]
        for sendDTO in sync.sends {
            guard let encryptedSend = sendDTO.sdkSend else { continue }
            do {
                let view = try client.sends().decrypt(send: encryptedSend)
                let send = map(view, serverURL: serverURL)
                sends.append(send)
                remoteSends[send.id] = RemoteSendState(encrypted: encryptedSend, view: view)
            } catch {
                continue
            }
        }
        return DecryptedVaultSnapshot(
            items: items,
            folders: folders,
            collections: collections,
            sends: sends,
            remoteCiphers: remoteCiphers,
            folderIDsByName: folderIDsByName,
            remoteSends: remoteSends,
            organizationKeys: Dictionary(
                uniqueKeysWithValues: (sync.profile?.organizations ?? []).compactMap { organization in
                    organization.key.map { (organization.id, $0) }
                }
            )
        )
    }

    private func initializeClient(
        _ client: Client,
        email: String,
        userID: String?,
        userKey: Data,
        kdf: KDFConfiguration,
        accountKeys: WrappedAccountKeys,
        organizations: [SyncOrganizationDTO]
    ) async throws {
        let sdkKDF = try kdf.sdkKDF
        try await client.crypto().initializeUserCrypto(
            req: InitUserCryptoRequest(
                userId: userID,
                kdfParams: sdkKDF,
                email: email,
                accountCryptographicState: accountKeys.sdkState,
                method: .decryptedKey(decryptedUserKey: userKey.base64EncodedString()),
                upgradeToken: nil
            )
        )
        let organizationKeys = Dictionary(
            uniqueKeysWithValues: organizations.compactMap { organization in
                organization.key.map { (organization.id, $0) }
            }
        )
        if !organizationKeys.isEmpty {
            try await client.crypto().initializeOrgCrypto(
                req: InitOrgCryptoRequest(organizationKeys: organizationKeys)
            )
        }
    }

    private func decodingDetails(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        let context: DecodingError.Context
        let reason: String
        switch decodingError {
        case let .keyNotFound(key, value):
            context = value
            reason = "missing \(key.stringValue)"
        case let .typeMismatch(_, value):
            context = value
            reason = "type mismatch"
        case let .valueNotFound(_, value):
            context = value
            reason = "missing value"
        case let .dataCorrupted(value):
            context = value
            reason = "invalid data"
        @unknown default:
            return "unknown JSON error"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? reason : "\(reason) at \(path)"
    }

    private func map(
        _ view: CipherView,
        folderName: String?,
        organizationName: String?,
        collectionIDs: [String]
    ) -> VaultItem {
        let login = view.login
        let card = view.card.map {
            CardDetails(
                cardholderName: $0.cardholderName ?? "",
                brand: $0.brand ?? "",
                number: $0.number ?? "",
                expirationMonth: $0.expMonth ?? "",
                expirationYear: $0.expYear ?? "",
                securityCode: $0.code ?? ""
            )
        }
        let identity = view.identity.map {
            IdentityDetails(
                title: $0.title ?? "",
                firstName: $0.firstName ?? "",
                middleName: $0.middleName ?? "",
                lastName: $0.lastName ?? "",
                username: $0.username ?? "",
                company: $0.company ?? "",
                email: $0.email ?? "",
                phone: $0.phone ?? "",
                socialSecurityNumber: $0.ssn ?? "",
                passportNumber: $0.passportNumber ?? "",
                licenseNumber: $0.licenseNumber ?? "",
                address1: $0.address1 ?? "",
                address2: [$0.address2, $0.address3].compactMap { $0 }.joined(separator: "\n"),
                city: $0.city ?? "",
                state: $0.state ?? "",
                postalCode: $0.postalCode ?? "",
                country: $0.country ?? ""
            )
        }
        let ssh = view.sshKey
        let loginURIs = login?.uris?.compactMap(\.uri) ?? []
        let firstURI = loginURIs.first ?? ""
        var risks = Set<VaultRisk>()
        if loginURIs.contains(where: { $0.lowercased().hasPrefix("http://") }) {
            risks.insert(.unsecured)
        }

        return VaultItem(
            id: view.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: view.name,
            username: login?.username ?? ssh?.publicKey ?? "",
            password: login?.password ?? ssh?.privateKey ?? "",
            uri: firstURI,
            additionalURIs: loginURIs.count > 1 ? Array(loginURIs.dropFirst()) : nil,
            type: view.localItemType,
            folder: folderName,
            organization: organizationName,
            collectionIDs: collectionIDs,
            notes: view.notes ?? ssh?.fingerprint ?? "",
            isFavorite: view.favorite,
            totpSecret: login?.totp,
            passkeyCount: login?.fido2Credentials?.count ?? 0,
            risks: risks,
            card: card,
            identity: identity,
            customFields: (view.fields ?? []).map { field in
                VaultCustomField(
                    name: field.name ?? "",
                    value: field.value ?? "",
                    type: field.type.localType
                )
            },
            createdAt: view.creationDate,
            deletedAt: view.deletedDate,
            archivedAt: view.archivedDate,
            updatedAt: view.revisionDate
        )
    }

    private func map(_ view: BitwardenSdk.SendView, serverURL: URL) -> SendItem {
        let shareURL: URL? = {
            guard let accessID = view.accessId, let key = view.key else { return nil }
            let base = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: "\(base)/#/send/\(accessID)/\(key)")
        }()
        return SendItem(
            id: view.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: view.name,
            kind: view.type == .file ? .file : .text,
            text: view.text?.text ?? "",
            fileName: view.file?.fileName,
            fileID: view.file?.id,
            fileSize: view.file?.sizeName ?? view.file?.size,
            accessCount: Int(view.accessCount),
            maximumAccessCount: view.maxAccessCount.map(Int.init),
            expiresAt: view.expirationDate,
            deletesAt: view.deletionDate,
            passwordProtected: view.hasPassword,
            isDisabled: view.disabled,
            shareURL: shareURL
        )
    }
}

private extension SyncSendDTO {
    nonisolated var sdkSend: BitwardenSdk.Send? {
        guard let revisionDate = ServerDateParser.parse(revisionDate),
              let deletionDate = ServerDateParser.parse(deletionDate) else {
            return nil
        }
        let sendType: BitwardenSdk.SendType = type == 1 ? .file : .text
        let resolvedAuthType: AuthType = switch authType {
        case 0: .email
        case 1: .password
        case 2: .none
        default: password != nil ? .password : (emails?.isEmpty == false ? .email : .none)
        }
        return BitwardenSdk.Send(
            id: id,
            accessId: accessId,
            name: name,
            notes: notes,
            key: key,
            password: password,
            type: sendType,
            file: file.map {
                SendFile(id: $0.id, fileName: $0.fileName, size: $0.size, sizeName: $0.sizeName)
            },
            text: text.map { SendText(text: $0.text, hidden: $0.hidden) },
            maxAccessCount: maxAccessCount,
            accessCount: accessCount,
            disabled: disabled,
            hideEmail: hideEmail,
            revisionDate: revisionDate,
            deletionDate: deletionDate,
            expirationDate: ServerDateParser.parse(expirationDate),
            emails: emails,
            authType: resolvedAuthType
        )
    }
}

private extension SyncCollectionDTO {
    nonisolated var sdkCollection: BitwardenSdk.Collection {
        BitwardenSdk.Collection(
            id: id,
            organizationId: organizationId,
            name: name,
            externalId: externalId,
            hidePasswords: hidePasswords,
            readOnly: readOnly,
            manage: manage ?? false,
            defaultUserCollectionEmail: defaultUserCollectionEmail,
            type: type == 1 ? .defaultUserCollection : .sharedCollection
        )
    }
}

private extension KDFConfiguration {
    nonisolated var sdkKDF: Kdf {
        get throws {
            guard iterations > 0, let iterations = UInt32(exactly: iterations) else {
                throw VaultCryptoError.invalidKDFParameters
            }
            switch type {
            case .pbkdf2SHA256:
                return .pbkdf2(iterations: iterations)
            case .argon2id:
                guard let memory, let parallelism,
                      memory > 0, parallelism > 0,
                      let memory = UInt32(exactly: memory),
                      let parallelism = UInt32(exactly: parallelism) else {
                    throw VaultCryptoError.invalidKDFParameters
                }
                return .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
            }
        }
    }
}

private extension WrappedAccountKeys {
    nonisolated var sdkState: WrappedAccountCryptographicState {
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

private extension SyncCipherDTO {
    nonisolated var sdkCipher: Cipher? {
        guard let creationDate = ServerDateParser.parse(creationDate),
              let revisionDate = ServerDateParser.parse(revisionDate),
              let cipherType else { return nil }
        return Cipher(
            id: id,
            organizationId: organizationId,
            folderId: folderId,
            collectionIds: collectionIds,
            key: key,
            name: name,
            notes: notes,
            type: cipherType,
            login: login?.sdkLogin,
            identity: identity?.sdkIdentity,
            card: card?.sdkCard,
            secureNote: secureNote.map { _ in SecureNote(type: .generic) },
            sshKey: sshKey?.sdkSSHKey,
            bankAccount: nil,
            driversLicense: nil,
            passport: nil,
            favorite: favorite,
            reprompt: reprompt == 0 ? .none : .password,
            organizationUseTotp: organizationUseTotp,
            edit: edit,
            permissions: nil,
            viewPassword: viewPassword,
            localData: nil,
            attachments: nil,
            fields: fields?.map(\.sdkField),
            passwordHistory: nil,
            creationDate: creationDate,
            deletedDate: ServerDateParser.parse(deletedDate),
            revisionDate: revisionDate,
            archivedDate: ServerDateParser.parse(archivedDate),
            data: data
        )
    }

    nonisolated var cipherType: BitwardenSdk.CipherType? {
        switch type {
        case 1: .login
        case 2: .secureNote
        case 3: .card
        case 4: .identity
        case 5: .sshKey
        default: nil
        }
    }
}

private extension SyncLoginDTO {
    nonisolated var sdkLogin: Login {
        Login(
            username: username,
            password: password,
            passwordRevisionDate: ServerDateParser.parse(passwordRevisionDate),
            uris: uris?.map(\.sdkURI),
            totp: totp,
            autofillOnPageLoad: autofillOnPageLoad,
            fido2Credentials: fido2Credentials?.compactMap(\.sdkCredential)
        )
    }
}

private extension SyncLoginURIDTO {
    nonisolated var sdkURI: LoginUri {
        LoginUri(uri: uri, match: match.flatMap(BitwardenSdk.UriMatchType.from), uriChecksum: uriChecksum)
    }
}

private extension BitwardenSdk.UriMatchType {
    nonisolated static func from(_ value: Int) -> Self? {
        switch value {
        case 0: .domain
        case 1: .host
        case 2: .startsWith
        case 3: .exact
        case 4: .regularExpression
        case 5: .never
        default: nil
        }
    }
}

private extension SyncFido2CredentialDTO {
    nonisolated var sdkCredential: Fido2Credential? {
        guard let creationDate = ServerDateParser.parse(creationDate) else { return nil }
        return Fido2Credential(
            credentialId: credentialId,
            keyType: keyType,
            keyAlgorithm: keyAlgorithm,
            keyCurve: keyCurve,
            keyValue: keyValue,
            rpId: rpId,
            userHandle: userHandle,
            userName: userName,
            counter: counter,
            rpName: rpName,
            userDisplayName: userDisplayName,
            discoverable: discoverable,
            creationDate: creationDate
        )
    }
}

private extension SyncCardDTO {
    nonisolated var sdkCard: Card {
        Card(
            cardholderName: cardholderName,
            expMonth: expMonth,
            expYear: expYear,
            code: code,
            brand: brand,
            number: number
        )
    }
}

private extension SyncIdentityDTO {
    nonisolated var sdkIdentity: Identity {
        Identity(
            title: title,
            firstName: firstName,
            middleName: middleName,
            lastName: lastName,
            address1: address1,
            address2: address2,
            address3: address3,
            city: city,
            state: state,
            postalCode: postalCode,
            country: country,
            company: company,
            email: email,
            phone: phone,
            ssn: ssn,
            username: username,
            passportNumber: passportNumber,
            licenseNumber: licenseNumber
        )
    }
}

private extension SyncSSHKeyDTO {
    nonisolated var sdkSSHKey: SshKey {
        SshKey(privateKey: privateKey, publicKey: publicKey, fingerprint: keyFingerprint)
    }
}

private extension SyncFieldDTO {
    nonisolated var sdkField: Field {
        Field(name: name, value: value, type: sdkType, linkedId: linkedId)
    }

    nonisolated var sdkType: BitwardenSdk.FieldType {
        switch type {
        case 1: .hidden
        case 2: .boolean
        case 3: .linked
        default: .text
        }
    }
}

private extension BitwardenSdk.FieldType {
    nonisolated var localType: VaultCustomFieldType {
        switch self {
        case .text: .text
        case .hidden: .hidden
        case .boolean: .boolean
        case .linked: .linked
        }
    }
}

private extension CipherView {
    nonisolated var localItemType: VaultItemType {
        switch type {
        case .login: .login
        case .secureNote: .secureNote
        case .card: .card
        case .identity: .identity
        case .sshKey: .sshKey
        default: .secureNote
        }
    }
}
