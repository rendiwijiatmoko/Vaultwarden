import BitwardenSdk
import Foundation

/// Network/crypto boundary. UI code receives only an opaque Keychain reference, never bearer tokens or keys.
nonisolated protocol VaultwardenService: Sendable {
    func discover(serverURL: URL) async throws -> ServerConfiguration
    func login(
        serverURL: URL,
        email: String,
        masterPassword: String,
        twoFactorCode: String?
    ) async throws -> AuthenticatedSession
    func pendingLoginRequests(session: AuthenticatedSession) async throws -> [PendingLoginRequest]
    func respondToLoginRequest(
        _ request: PendingLoginRequest,
        approved: Bool,
        session: AuthenticatedSession
    ) async throws
    func sync(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot
    func loadCachedVault(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot
    func refreshEncryptedCache(session: AuthenticatedSession) async throws
    func clearEncryptedCache(session: AuthenticatedSession) async throws
    func publishAutoFillIndex(snapshot: DecryptedVaultSnapshot, session: AuthenticatedSession) async
    func executeMutation(_ mutation: PreparedVaultMutation, session: AuthenticatedSession) async throws
    func rebaseMutation(_ mutation: PreparedVaultMutation, session: AuthenticatedSession) async throws -> PreparedVaultMutation
    func prepareSaveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation
    func prepareCipherAction(id: UUID, action: CipherMutationAction, session: AuthenticatedSession) -> PreparedVaultMutation
    func prepareFolderWrite(
        folder: VaultFolder,
        previousName: String?,
        serverID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation
    func prepareFolderDelete(folder: VaultFolder, serverID: String?, session: AuthenticatedSession) -> PreparedVaultMutation
    func prepareSendWrite(
        item: SendItem,
        password: String?,
        passwordUpdate: SendPasswordUpdate,
        existing: RemoteSendState?,
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation
    func prepareSendPasswordRemoval(item: SendItem, session: AuthenticatedSession) -> PreparedVaultMutation
    func prepareSendDelete(id: UUID, session: AuthenticatedSession) -> PreparedVaultMutation
    func createFileSend(
        item: SendItem,
        password: String?,
        fileURL: URL,
        session: AuthenticatedSession
    ) async throws -> UUID
    func downloadAndDecryptSendFile(
        item: SendItem,
        remote: RemoteSendState,
        password: String?,
        session: AuthenticatedSession
    ) async throws -> URL
    func uploadAttachment(
        fileURL: URL,
        fileName: String,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws
    func downloadAttachment(
        attachment: VaultAttachment,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> URL
    func deleteAttachment(
        attachmentID: String,
        cipher: RemoteCipherState,
        session: AuthenticatedSession
    ) async throws
    func unlock(session: AuthenticatedSession) async throws
    func unlock(session: AuthenticatedSession, masterPassword: String) async throws
    func lock(session: AuthenticatedSession?) async
    func logout(session: AuthenticatedSession) async throws
    func saveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws
    func softDeleteCipher(id: UUID, session: AuthenticatedSession) async throws
    func restoreCipher(id: UUID, session: AuthenticatedSession) async throws
    func permanentlyDeleteCipher(id: UUID, session: AuthenticatedSession) async throws
    func createFolder(name: String, organizationKeys: [String: String], session: AuthenticatedSession) async throws
    func updateFolder(id: String, name: String, organizationKeys: [String: String], session: AuthenticatedSession) async throws
    func deleteFolder(id: String, session: AuthenticatedSession) async throws
    func createTextSend(item: SendItem, password: String?, session: AuthenticatedSession) async throws
    func updateSend(item: SendItem, existing: RemoteSendState, session: AuthenticatedSession) async throws
    func deleteSend(id: UUID, session: AuthenticatedSession) async throws
}

nonisolated enum CipherMutationAction: Sendable {
    case trash
    case restore
    case archive
    case unarchive
    case delete
}

struct ServerConfiguration: Sendable {
    let serverURL: URL
    let version: String?
}

struct AuthenticatedSession: Sendable {
    let accountID: String
    let serverURL: URL
    let tokenReference: String
}

struct PendingLoginRequest: Identifiable, Equatable, Sendable {
    let id: String
    let publicKey: String
    let deviceType: String
    let ipAddress: String
    let creationDate: Date
    let origin: String?
}

struct EncryptedVaultSnapshot: Sendable {
    let revision: Date
    let encryptedPayload: Data
    let decrypted: DecryptedVaultSnapshot
    let isFromOfflineCache: Bool
}

enum VaultwardenServiceError: LocalizedError {
    case invalidServerURL
    case insecureTransport
    case invalidResponse
    case serverRejected(status: Int, message: String?)
    case twoFactorRequired
    case sessionExpired
    case vaultLocked
    case invalidTokenResponse(field: String)
    case invalidFileSendResponse
    case missingSendFile
    case sendFileTooLarge
    case unsupportedFileUpload
    case archiveNotSupported
    case missingAttachment

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "The server URL is invalid."
        case .insecureTransport: "Vaultwarden must be accessed over HTTPS."
        case .invalidResponse: "The server returned an invalid response."
        case let .serverRejected(status, message):
            message ?? "The server rejected the request (HTTP \(status))."
        case .twoFactorRequired: "Enter the 6-digit verification code from your authenticator app."
        case .sessionExpired: "The session has expired. Please sign in again."
        case .vaultLocked: "Unlock the vault before syncing."
        case let .invalidTokenResponse(field):
            "The token response is missing or has an invalid '\(field)' field."
        case .invalidFileSendResponse: "Vaultwarden returned an invalid file Send response."
        case .missingSendFile: "The selected Send file is no longer available."
        case .sendFileTooLarge: "Send files must be 100 MB or smaller."
        case .unsupportedFileUpload: "This server returned an unsupported file upload target."
        case .archiveNotSupported:
            "This Vaultwarden server does not support archiving items. Update the server, then try again."
        case .missingAttachment: "This attachment is unavailable. Sync the vault and try again."
        }
    }
}

struct DefaultVaultwardenService: VaultwardenService {
    private let httpClient: any HTTPClient
    private let cryptoProvider: any VaultCryptoProvider
    private let sessionStore: any SessionStore
    private let payloadDecoder: any VaultPayloadDecoder
    private let cacheStore: any VaultCacheStore
    private let keyMemory: VaultKeyMemory
    private let unlockPresentationAllowed: @MainActor @Sendable () -> Bool

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        cryptoProvider: any VaultCryptoProvider = BitwardenSDKCryptoProvider(),
        sessionStore: any SessionStore = KeychainSessionStore(),
        payloadDecoder: any VaultPayloadDecoder = BitwardenVaultPayloadDecoder(),
        cacheStore: any VaultCacheStore = EncryptedVaultCacheStore(),
        keyMemory: VaultKeyMemory = VaultKeyMemory(),
        unlockPresentationAllowed: @escaping @MainActor @Sendable () -> Bool = { UnlockPresentationPolicy.isAllowed }
    ) {
        self.httpClient = httpClient
        self.cryptoProvider = cryptoProvider
        self.sessionStore = sessionStore
        self.payloadDecoder = payloadDecoder
        self.cacheStore = cacheStore
        self.keyMemory = keyMemory
        self.unlockPresentationAllowed = unlockPresentationAllowed
    }

    func discover(serverURL: URL) async throws -> ServerConfiguration {
        let baseURL = try validatedBaseURL(serverURL)
        var request = URLRequest(url: endpoint(baseURL, path: "api/config"))
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        let (data, response) = try await httpClient.data(for: request)
        try validate(response: response, data: data)
        let configuration = try? BitwardenJSONDecoder.make().decode(ServerConfigDTO.self, from: data)
        return ServerConfiguration(serverURL: baseURL, version: configuration?.version)
    }

    func login(
        serverURL: URL,
        email: String,
        masterPassword: String,
        twoFactorCode: String?
    ) async throws -> AuthenticatedSession {
        let baseURL = try validatedBaseURL(serverURL)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !masterPassword.isEmpty else {
            throw VaultwardenServiceError.invalidResponse
        }

        _ = try await discover(serverURL: baseURL)
        let kdf = try await preLogin(baseURL: baseURL, email: normalizedEmail)
        let authenticationHash = try await cryptoProvider.authenticationHash(
            email: normalizedEmail,
            masterPassword: masterPassword,
            kdf: kdf
        )
        let token = try await requestPasswordToken(
            baseURL: baseURL,
            email: normalizedEmail,
            authenticationHash: authenticationHash,
            twoFactorCode: twoFactorCode
        )

        guard let userID = token.userID else {
            throw VaultwardenServiceError.invalidTokenResponse(field: "sub")
        }
        guard let protectedUserKey = token.protectedUserKey,
              let accountKeys = wrappedAccountKeys(from: token) else {
            throw VaultCryptoError.missingAccountKeys
        }
        let userKey = try await cryptoProvider.unwrapUserKey(
            userID: userID,
            email: normalizedEmail,
            masterPassword: masterPassword,
            kdf: kdf,
            protectedUserKey: protectedUserKey,
            accountKeys: accountKeys
        )

        let reference = sessionReference(baseURL: baseURL, email: normalizedEmail)
        try sessionStore.save(
            StoredSessionCredentials(
                userID: userID,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                tokenType: token.tokenType,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
                protectedUserKey: token.protectedUserKey,
                protectedPrivateKey: token.protectedPrivateKey,
                kdf: kdf,
                accountKeys: accountKeys
            ),
            reference: reference
        )
        try sessionStore.saveVaultKey(userKey, reference: reference)
        await keyMemory.store(userKey, reference: reference)
        return AuthenticatedSession(accountID: normalizedEmail, serverURL: baseURL, tokenReference: reference)
    }

    func pendingLoginRequests(session: AuthenticatedSession) async throws -> [PendingLoginRequest] {
        let (data, _) = try await authenticatedResponse(
            session: session,
            method: "GET",
            path: "api/auth-requests/pending"
        )
        guard let response = try? BitwardenJSONDecoder.make().decode(PendingLoginRequestListDTO.self, from: data) else {
            throw VaultwardenServiceError.invalidResponse
        }
        return try response.data.map { request in
            guard UUID(uuidString: request.id) != nil,
                  !request.publicKey.isEmpty,
                  let creationDate = Self.parseServerDate(request.creationDate) else {
                throw VaultwardenServiceError.invalidResponse
            }
            return PendingLoginRequest(
                id: request.id,
                publicKey: request.publicKey,
                deviceType: request.requestDeviceType,
                ipAddress: request.requestIpAddress,
                creationDate: creationDate,
                origin: request.origin
            )
        }.sorted { $0.creationDate > $1.creationDate }
    }

    func respondToLoginRequest(
        _ request: PendingLoginRequest,
        approved: Bool,
        session: AuthenticatedSession
    ) async throws {
        let encryptedUserKey: String
        if approved {
            let credentials = try sessionStore.load(reference: session.tokenReference)
            guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
                throw VaultwardenServiceError.vaultLocked
            }
            let client = try await BitwardenCipherWriter.initializedClient(
                email: session.accountID,
                userKey: userKey,
                credentials: credentials,
                organizationKeys: [:]
            )
            encryptedUserKey = try client.auth().approveAuthRequest(publicKey: request.publicKey)
        } else {
            encryptedUserKey = ""
        }

        let body = try JSONEncoder().encode(
            LoginRequestResponseDTO(
                deviceIdentifier: deviceIdentifier,
                key: encryptedUserKey,
                masterPasswordHash: nil,
                requestApproved: approved
            )
        )
        _ = try await authenticatedResponse(
            session: session,
            method: "PUT",
            path: "api/auth-requests/\(request.id)",
            body: body
        )
    }

    private func wrappedAccountKeys(from token: IdentityTokenResponseDTO) -> WrappedAccountKeys? {
        if let v2 = token.accountKeys {
            return WrappedAccountKeys(
                privateKey: v2.publicKeyEncryptionKeyPair.wrappedPrivateKey,
                signedPublicKey: v2.publicKeyEncryptionKeyPair.signedPublicKey,
                signingKey: v2.signatureKeyPair?.wrappedSigningKey,
                securityState: v2.securityState?.securityState
            )
        }
        guard let privateKey = token.protectedPrivateKey else { return nil }
        return WrappedAccountKeys(
            privateKey: privateKey,
            signedPublicKey: nil,
            signingKey: nil,
            securityState: nil
        )
    }

    func sync(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot {
        var credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }

        let data: Data
        let isFromOfflineCache: Bool
        do {
            if credentials.expiresAt <= Date().addingTimeInterval(30) {
                credentials = try await refreshCredentials(
                    baseURL: session.serverURL,
                    current: credentials,
                    reference: session.tokenReference
                )
            }
            var result = try await syncResponse(baseURL: session.serverURL, credentials: credentials)
            if result.1.statusCode == 401 {
                credentials = try await refreshCredentials(
                    baseURL: session.serverURL,
                    current: credentials,
                    reference: session.tokenReference
                )
                result = try await syncResponse(baseURL: session.serverURL, credentials: credentials)
            }
            try validate(response: result.1, data: result.0)
            data = result.0
            isFromOfflineCache = false
            try? cacheStore.save(payload: data, reference: session.tokenReference)
        } catch let error as HTTPClientError where error.allowsOfflineFallback {
            data = try cacheStore.load(reference: session.tokenReference)
            isFromOfflineCache = true
        }

        let decrypted = try await payloadDecoder.decode(
            payload: data,
            serverURL: session.serverURL,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials
        )
        await AutoFillVaultPublisher.publish(
            snapshot: decrypted,
            userKey: userKey,
            accountReference: session.tokenReference,
            email: session.accountID,
            serverURL: session.serverURL,
            credentials: credentials
        )
        return EncryptedVaultSnapshot(
            revision: Date(),
            encryptedPayload: data,
            decrypted: decrypted,
            isFromOfflineCache: isFromOfflineCache
        )
    }

    func loadCachedVault(session: AuthenticatedSession) async throws -> EncryptedVaultSnapshot {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let data = try cacheStore.load(reference: session.tokenReference)
        let decrypted = try await payloadDecoder.decode(
            payload: data,
            serverURL: session.serverURL,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials
        )
        await AutoFillVaultPublisher.publish(
            snapshot: decrypted,
            userKey: userKey,
            accountReference: session.tokenReference,
            email: session.accountID,
            serverURL: session.serverURL,
            credentials: credentials
        )
        return EncryptedVaultSnapshot(
            revision: Date(),
            encryptedPayload: data,
            decrypted: decrypted,
            isFromOfflineCache: true
        )
    }

    func refreshEncryptedCache(session: AuthenticatedSession) async throws {
        let result = try await authenticatedSyncResponse(session: session)
        try validate(response: result.1, data: result.0)
        try cacheStore.save(payload: result.0, reference: session.tokenReference)
    }

    func clearEncryptedCache(session: AuthenticatedSession) async throws {
        try cacheStore.delete(reference: session.tokenReference)
    }

    func publishAutoFillIndex(snapshot: DecryptedVaultSnapshot, session: AuthenticatedSession) async {
        guard let userKey = await keyMemory.load(reference: session.tokenReference),
              let credentials = try? sessionStore.load(reference: session.tokenReference) else { return }
        await AutoFillVaultPublisher.publish(
            snapshot: snapshot,
            userKey: userKey,
            accountReference: session.tokenReference,
            email: session.accountID,
            serverURL: session.serverURL,
            credentials: credentials
        )
    }

    func executeMutation(_ mutation: PreparedVaultMutation, session: AuthenticatedSession) async throws {
        do {
            _ = try await authenticatedResponse(
                session: session,
                method: mutation.method,
                path: mutation.path,
                body: mutation.body,
                requestID: mutation.id.uuidString.lowercased()
            )
        } catch let error as VaultwardenServiceError {
            if Self.isArchiveMutation(mutation),
               case let .serverRejected(status, _) = error,
               status == 404 || status == 405 {
                throw VaultwardenServiceError.archiveNotSupported
            }
            throw error
        }
    }

    private nonisolated static func isArchiveMutation(_ mutation: PreparedVaultMutation) -> Bool {
        guard mutation.entity == .cipher, mutation.method == "PUT" else { return false }
        return mutation.path.hasSuffix("/archive") || mutation.path.hasSuffix("/unarchive")
    }

    func rebaseMutation(
        _ mutation: PreparedVaultMutation,
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        guard mutation.entity == .cipher,
              mutation.method == "PUT",
              let body = mutation.body else { return mutation }

        let result = try await authenticatedSyncResponse(session: session)
        try validate(response: result.1, data: result.0)
        try? cacheStore.save(payload: result.0, reference: session.tokenReference)
        let sync = try BitwardenJSONDecoder.make().decode(SyncResponseDTO.self, from: result.0)
        guard let remote = sync.ciphers.first(where: { $0.id.caseInsensitiveCompare(mutation.entityID) == .orderedSame }),
              let revision = ServerDateParser.parse(remote.revisionDate),
              var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return mutation
        }
        object["lastKnownRevisionDate"] = Self.serverDateFormatter.string(from: revision)
        var rebased = mutation
        rebased.body = try JSONSerialization.data(withJSONObject: object)
        rebased.baseRevision = revision
        rebased.lastError = nil
        return rebased
    }

    func prepareSaveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let context = try await BitwardenCipherWriter.encrypt(
            item: item,
            existing: existing,
            folderID: folderID,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        let body = try bitwardenEncoder.encode(CipherWriteRequestDTO(context: context))
        let remoteID = existing?.view.id
        return PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .cipher,
            entityID: remoteID ?? item.id.uuidString.lowercased(),
            method: remoteID == nil ? "POST" : "PUT",
            path: remoteID.map { "api/ciphers/\($0)" } ?? "api/ciphers",
            body: body,
            projection: .upsertItem(item),
            baseRevision: existing?.view.revisionDate
        )
    }

    func prepareCipherAction(
        id: UUID,
        action: CipherMutationAction,
        session: AuthenticatedSession
    ) -> PreparedVaultMutation {
        let value = id.uuidString.lowercased()
        switch action {
        case .trash:
            return PreparedVaultMutation(
                accountReference: session.tokenReference,
                entity: .cipher,
                entityID: value,
                method: "PUT",
                path: "api/ciphers/\(value)/delete",
                projection: .trashItem(id: id, deletedAt: Date())
            )
        case .restore:
            return PreparedVaultMutation(
                accountReference: session.tokenReference,
                entity: .cipher,
                entityID: value,
                method: "PUT",
                path: "api/ciphers/\(value)/restore",
                projection: .restoreItem(id: id)
            )
        case .archive:
            return PreparedVaultMutation(
                accountReference: session.tokenReference,
                entity: .cipher,
                entityID: value,
                method: "PUT",
                path: "api/ciphers/\(value)/archive",
                projection: .archiveItem(id: id, archivedAt: Date())
            )
        case .unarchive:
            return PreparedVaultMutation(
                accountReference: session.tokenReference,
                entity: .cipher,
                entityID: value,
                method: "PUT",
                path: "api/ciphers/\(value)/unarchive",
                projection: .unarchiveItem(id: id)
            )
        case .delete:
            return PreparedVaultMutation(
                accountReference: session.tokenReference,
                entity: .cipher,
                entityID: value,
                method: "DELETE",
                path: "api/ciphers/\(value)",
                projection: .deleteItem(id: id)
            )
        }
    }

    func prepareFolderWrite(
        folder: VaultFolder,
        previousName: String?,
        serverID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        let body = try await encryptedFolderBody(
            id: serverID,
            name: folder.name,
            organizationKeys: organizationKeys,
            session: session
        )
        return PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .folder,
            entityID: serverID ?? folder.id.uuidString.lowercased(),
            method: serverID == nil ? "POST" : "PUT",
            path: serverID.map { "api/folders/\($0)" } ?? "api/folders",
            body: body,
            projection: .upsertFolder(folder: folder, previousName: previousName)
        )
    }

    func prepareFolderDelete(
        folder: VaultFolder,
        serverID: String?,
        session: AuthenticatedSession
    ) -> PreparedVaultMutation {
        let entityID = serverID ?? folder.id.uuidString.lowercased()
        return PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .folder,
            entityID: entityID,
            method: "DELETE",
            path: "api/folders/\(entityID)",
            projection: .deleteFolder(id: folder.id, name: folder.name)
        )
    }

    func prepareSendWrite(
        item: SendItem,
        password: String?,
        passwordUpdate: SendPasswordUpdate,
        existing: RemoteSendState?,
        session: AuthenticatedSession
    ) async throws -> PreparedVaultMutation {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let encrypted: BitwardenSdk.Send
        let passwordOverride: String?
        if let existing {
            encrypted = try await BitwardenCipherWriter.encryptUpdatedSend(
                item: item,
                existing: existing.view,
                passwordUpdate: passwordUpdate,
                email: session.accountID,
                userKey: userKey,
                credentials: credentials
            )
            if case let .set(newPassword) = passwordUpdate {
                passwordOverride = try Self.sendAccessPassword(
                    newPassword,
                    sendKeyBase64URL: existing.view.key
                )
            } else {
                passwordOverride = nil
            }
        } else {
            let prepared = try await BitwardenCipherWriter.encryptTextSendPrepared(
                item: item,
                password: password,
                email: session.accountID,
                userKey: userKey,
                credentials: credentials
            )
            encrypted = prepared.send
            passwordOverride = try Self.sendAccessPassword(
                password,
                sendKeyBase64URL: try prepared.client.sends().decrypt(send: prepared.send).key
            )
        }
        let body = try bitwardenEncoder.encode(
            SendWriteRequestDTO(encrypted, passwordOverride: passwordOverride)
        )
        let remoteID = existing?.view.id
        return PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .send,
            entityID: remoteID ?? item.id.uuidString.lowercased(),
            method: remoteID == nil ? "POST" : "PUT",
            path: remoteID.map { "api/sends/\($0)" } ?? "api/sends",
            body: body,
            projection: .upsertSend(item)
        )
    }

    func prepareSendPasswordRemoval(
        item: SendItem,
        session: AuthenticatedSession
    ) -> PreparedVaultMutation {
        PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .sendPassword,
            entityID: item.id.uuidString.lowercased(),
            method: "PUT",
            path: "api/sends/\(item.id.uuidString.lowercased())/remove-password",
            projection: .upsertSend(item)
        )
    }

    func prepareSendDelete(id: UUID, session: AuthenticatedSession) -> PreparedVaultMutation {
        let value = id.uuidString.lowercased()
        return PreparedVaultMutation(
            accountReference: session.tokenReference,
            entity: .send,
            entityID: value,
            method: "DELETE",
            path: "api/sends/\(value)",
            projection: .deleteSend(id: id)
        )
    }

    func createFileSend(
        item: SendItem,
        password: String?,
        fileURL: URL,
        session: AuthenticatedSession
    ) async throws -> UUID {
        let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer { if accessedSecurityScope { fileURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultwardenServiceError.missingSendFile
        }
        let sourceHandle = try FileHandle(forReadingFrom: fileURL)
        let sourceSize: UInt64
        do {
            sourceSize = try sourceHandle.seekToEnd()
            try sourceHandle.close()
        } catch {
            try? sourceHandle.close()
            throw error
        }
        guard sourceSize <= UInt64(100 * 1_024 * 1_024) else {
            throw VaultwardenServiceError.sendFileTooLarge
        }
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let prepared = try await BitwardenCipherWriter.encryptFileSend(
            item: item,
            password: password,
            fileName: item.fileName ?? fileURL.lastPathComponent,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials
        )
        guard let encryptedFileName = prepared.send.file?.fileName else {
            throw VaultwardenServiceError.invalidFileSendResponse
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedSendUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let encryptedURL = temporaryDirectory.appendingPathComponent("payload.send")
        try prepared.client.sends().encryptFile(
            send: prepared.send,
            decryptedFilePath: fileURL.path,
            encryptedFilePath: encryptedURL.path
        )
        let encryptedSize = try encryptedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let passwordOverride = try Self.sendAccessPassword(
            password,
            sendKeyBase64URL: try prepared.client.sends().decrypt(send: prepared.send).key
        )
        let body = try bitwardenEncoder.encode(
            SendWriteRequestDTO(
                prepared.send,
                fileLength: Int64(encryptedSize),
                passwordOverride: passwordOverride
            )
        )
        let (responseData, _) = try await authenticatedResponse(
            session: session,
            method: "POST",
            path: "api/sends/file/v2",
            body: body
        )
        guard let upload = try? BitwardenJSONDecoder.make().decode(FileSendUploadResponseDTO.self, from: responseData),
              let sendID = upload.sendResponse?.id ?? upload.sendIDFromPath,
              let createdSendID = UUID(uuidString: sendID) else {
            throw VaultwardenServiceError.invalidFileSendResponse
        }

        do {
            switch upload.fileUploadType {
            case 0:
                let multipart = try makeMultipartFile(
                    encryptedFileURL: encryptedURL,
                    fileName: encryptedFileName,
                    directory: temporaryDirectory
                )
                _ = try await authenticatedUploadResponse(
                    session: session,
                    method: "POST",
                    path: Self.directUploadPath(upload.url),
                    fileURL: multipart.url,
                    contentType: "multipart/form-data; boundary=\(multipart.boundary)"
                )
            case 1:
                guard let url = URL(string: upload.url), url.scheme?.hasPrefix("http") == true else {
                    throw VaultwardenServiceError.unsupportedFileUpload
                }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await httpClient.upload(for: request, fromFile: encryptedURL)
                try validate(response: response, data: data)
            default:
                throw VaultwardenServiceError.unsupportedFileUpload
            }
        } catch {
            // The v2 metadata call creates the Send before the data upload. Avoid leaving
            // a permanently broken Send if encryption/upload fails afterward.
            try? await deleteSend(id: UUID(uuidString: sendID) ?? item.id, session: session)
            throw error
        }
        return createdSendID
    }

    func uploadAttachment(
        fileURL: URL,
        fileName: String,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        guard let cipherID = cipher.view.id else { throw VaultwardenServiceError.missingAttachment }
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let client = try await BitwardenCipherWriter.initializedClient(
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedAttachmentUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptedURL = directory.appendingPathComponent("payload.enc")
        let attachment = try client.vault().attachments().encryptFile(
            cipher: cipher.encrypted,
            attachment: AttachmentView(
                id: nil, url: nil, size: nil, sizeName: nil,
                fileName: fileName, key: nil
            ),
            decryptedFilePath: fileURL.path,
            encryptedFilePath: encryptedURL.path
        )
        guard let encryptedName = attachment.fileName, let encryptedKey = attachment.key else {
            throw VaultwardenServiceError.missingAttachment
        }
        let encryptedSize = try encryptedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let body = try bitwardenEncoder.encode(AttachmentUploadRequestDTO(
            key: encryptedKey, fileName: encryptedName, fileSize: encryptedSize
        ))
        let (responseData, _) = try await authenticatedResponse(
            session: session, method: "POST",
            path: "api/ciphers/\(cipherID)/attachment/v2", body: body
        )
        let upload = try BitwardenJSONDecoder.make().decode(AttachmentUploadResponseDTO.self, from: responseData)
        do {
            switch upload.fileUploadType {
            case 0:
                let multipart = try makeMultipartFile(
                    encryptedFileURL: encryptedURL,
                    fileName: "attachment.enc",
                    directory: directory
                )
                _ = try await authenticatedUploadResponse(
                    session: session, method: "POST",
                    path: Self.directUploadPath(upload.url),
                    fileURL: multipart.url,
                    contentType: "multipart/form-data; boundary=\(multipart.boundary)"
                )
            case 1:
                guard let url = URL(string: upload.url), url.scheme == "https" else {
                    throw VaultwardenServiceError.unsupportedFileUpload
                }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await httpClient.upload(for: request, fromFile: encryptedURL)
                try validate(response: response, data: data)
            default:
                throw VaultwardenServiceError.unsupportedFileUpload
            }
        } catch {
            _ = try? await authenticatedResponse(
                session: session, method: "DELETE",
                path: "api/ciphers/\(cipherID)/attachment/\(upload.attachmentId)"
            )
            throw error
        }
    }

    func deleteAttachment(
        attachmentID: String,
        cipher: RemoteCipherState,
        session: AuthenticatedSession
    ) async throws {
        guard let cipherID = cipher.view.id,
              cipher.view.attachments?.contains(where: { $0.id == attachmentID }) == true else {
            throw VaultwardenServiceError.missingAttachment
        }
        _ = try await authenticatedResponse(
            session: session,
            method: "DELETE",
            path: "api/ciphers/\(cipherID)/attachment/\(attachmentID)"
        )
    }

    func downloadAttachment(
        attachment: VaultAttachment,
        cipher: RemoteCipherState,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> URL {
        guard let cipherID = cipher.view.id,
              let view = cipher.view.attachments?.first(where: { $0.id == attachment.id }) else {
            throw VaultwardenServiceError.missingAttachment
        }
        let (accessData, _) = try await authenticatedResponse(
            session: session, method: "GET",
            path: "api/ciphers/\(cipherID)/attachment/\(attachment.id)"
        )
        let access = try BitwardenJSONDecoder.make().decode(AttachmentDownloadResponseDTO.self, from: accessData)
        guard let url = URL(string: access.url, relativeTo: session.serverURL)?.absoluteURL,
              url.scheme == "https" else { throw VaultwardenServiceError.missingAttachment }
        let (encryptedURL, response) = try await httpClient.download(for: URLRequest(url: url))
        try validate(response: response, data: Data())
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let client = try await BitwardenCipherWriter.initializedClient(
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecryptedAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(Self.safeFileName(attachment.fileName))
        do {
            try client.vault().attachments().decryptFile(
                cipher: cipher.encrypted, attachment: view,
                encryptedFilePath: encryptedURL.path,
                decryptedFilePath: outputURL.path
            )
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func downloadAndDecryptSendFile(
        item: SendItem,
        remote: RemoteSendState,
        password: String?,
        session: AuthenticatedSession
    ) async throws -> URL {
        guard let fileID = remote.view.file?.id ?? item.fileID,
              let sendID = remote.view.id else { throw VaultwardenServiceError.missingSendFile }
        let accessPassword = try Self.sendAccessPassword(
            password,
            sendKeyBase64URL: remote.view.key
        )
        let passwordBody = try JSONEncoder().encode(SendFileAccessRequestDTO(password: accessPassword))
        let (accessData, _) = try await authenticatedResponse(
            session: session,
            method: "POST",
            path: "api/sends/\(sendID)/access/file/\(fileID)",
            body: passwordBody
        )
        guard let access = try? BitwardenJSONDecoder.make().decode(SendFileDownloadResponseDTO.self, from: accessData),
              let downloadURL = URL(string: access.url, relativeTo: session.serverURL)?.absoluteURL else {
            throw VaultwardenServiceError.invalidFileSendResponse
        }
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        let (temporaryEncryptedURL, response) = try await httpClient.download(for: request)
        try validate(response: response, data: Data())

        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let client = try await BitwardenCipherWriter.initializedClient(
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: [:]
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecryptedSends", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent(Self.safeFileName(item.fileName ?? "Send file"))
        try client.sends().decryptFile(
            send: remote.encrypted,
            encryptedFilePath: temporaryEncryptedURL.path,
            decryptedFilePath: outputURL.path
        )
        return outputURL
    }

    /// Bitwarden Send access endpoints never receive the recipient's plaintext password.
    /// They expect PBKDF2-HMAC-SHA256(password, raw 16-byte Send key, 100_000),
    /// encoded as standard Base64. Do not normalize the password: spaces and symbols are
    /// valid password characters and must be hashed byte-for-byte as entered.
    private static func sendAccessPassword(
        _ password: String?,
        sendKeyBase64URL: String?
    ) throws -> String? {
        guard let password, !password.isEmpty else { return nil }
        guard let sendKeyBase64URL,
              let sendKey = decodeBase64URL(sendKeyBase64URL),
              sendKey.count == 16 else {
            throw VaultwardenServiceError.invalidFileSendResponse
        }
        let passwordHash = try PBKDF2SHA256.derive(
            password: Data(password.utf8),
            salt: sendKey,
            iterations: 100_000,
            outputByteCount: 32
        )
        return passwordHash.base64EncodedString()
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private func syncResponse(
        baseURL: URL,
        credentials: StoredSessionCredentials
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint(baseURL, path: "api/sync"))
        request.httpMethod = "GET"
        request.setValue("\(credentials.tokenType) \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        applyCommonHeaders(to: &request)
        return try await httpClient.data(for: request)
    }

    private func authenticatedSyncResponse(
        session: AuthenticatedSession
    ) async throws -> (Data, HTTPURLResponse) {
        var credentials = try sessionStore.load(reference: session.tokenReference)
        if credentials.expiresAt <= Date().addingTimeInterval(30) {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
        }
        var result = try await syncResponse(baseURL: session.serverURL, credentials: credentials)
        if result.1.statusCode == 401 {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
            result = try await syncResponse(baseURL: session.serverURL, credentials: credentials)
        }
        return result
    }

    func unlock(session: AuthenticatedSession) async throws {
        if await keyMemory.load(reference: session.tokenReference) != nil { return }
        // Recheck after the actor hop, immediately before Keychain can present
        // Touch ID. A queued unlock must not steal focus from another app.
        let key = try await MainActor.run {
            guard unlockPresentationAllowed(), !Task.isCancelled else { throw CancellationError() }
            return try sessionStore.loadVaultKey(
                reference: session.tokenReference,
                reason: "Unlock your encrypted vault"
            )
        }
        guard key.count == 64 else { throw VaultCryptoError.invalidUserKey }
        await keyMemory.store(key, reference: session.tokenReference)
    }

    func unlock(session: AuthenticatedSession, masterPassword: String) async throws {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let kdf = credentials.kdf,
              let userID = credentials.userID,
              let protectedUserKey = credentials.protectedUserKey,
              let accountKeys = credentials.accountKeys else {
            throw VaultCryptoError.missingAccountKeys
        }
        let key = try await cryptoProvider.unwrapUserKey(
            userID: userID,
            email: session.accountID,
            masterPassword: masterPassword,
            kdf: kdf,
            protectedUserKey: protectedUserKey,
            accountKeys: accountKeys
        )
        try sessionStore.saveVaultKey(key, reference: session.tokenReference)
        await keyMemory.store(key, reference: session.tokenReference)
    }

    func lock(session: AuthenticatedSession?) async {
        await keyMemory.clear(reference: session?.tokenReference)
    }

    func logout(session: AuthenticatedSession) async throws {
        await keyMemory.clear(reference: session.tokenReference)
        await AutoFillVaultPublisher.clear(accountReference: session.tokenReference)
        var cleanupFailure: Error?
        do {
            try cacheStore.delete(reference: session.tokenReference)
        } catch {
            cleanupFailure = error
        }
        do {
            try sessionStore.delete(reference: session.tokenReference)
        } catch {
            cleanupFailure = cleanupFailure ?? error
        }
        if let cleanupFailure { throw cleanupFailure }
    }

    func saveCipher(
        item: VaultItem,
        existing: RemoteCipherState?,
        folderID: String?,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let context = try await BitwardenCipherWriter.encrypt(
            item: item,
            existing: existing,
            folderID: folderID,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        let body = try bitwardenEncoder.encode(CipherWriteRequestDTO(context: context))
        let path: String
        let method: String
        if let id = existing?.view.id {
            path = "api/ciphers/\(id)"
            method = "PUT"
        } else {
            path = "api/ciphers"
            method = "POST"
        }
        _ = try await authenticatedResponse(session: session, method: method, path: path, body: body)
    }

    func softDeleteCipher(id: UUID, session: AuthenticatedSession) async throws {
        _ = try await authenticatedResponse(
            session: session,
            method: "PUT",
            path: "api/ciphers/\(id.uuidString.lowercased())/delete"
        )
    }

    func restoreCipher(id: UUID, session: AuthenticatedSession) async throws {
        _ = try await authenticatedResponse(
            session: session,
            method: "PUT",
            path: "api/ciphers/\(id.uuidString.lowercased())/restore"
        )
    }

    func permanentlyDeleteCipher(id: UUID, session: AuthenticatedSession) async throws {
        _ = try await authenticatedResponse(
            session: session,
            method: "DELETE",
            path: "api/ciphers/\(id.uuidString.lowercased())"
        )
    }

    func createFolder(
        name: String,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        try await writeFolder(
            id: nil,
            name: name,
            organizationKeys: organizationKeys,
            session: session
        )
    }

    func updateFolder(
        id: String,
        name: String,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        try await writeFolder(
            id: id,
            name: name,
            organizationKeys: organizationKeys,
            session: session
        )
    }

    private func writeFolder(
        id: String?,
        name: String,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws {
        let body = try await encryptedFolderBody(
            id: id,
            name: name,
            organizationKeys: organizationKeys,
            session: session
        )
        _ = try await authenticatedResponse(
            session: session,
            method: id == nil ? "POST" : "PUT",
            path: id.map { "api/folders/\($0)" } ?? "api/folders",
            body: body
        )
    }

    private func encryptedFolderBody(
        id: String?,
        name: String,
        organizationKeys: [String: String],
        session: AuthenticatedSession
    ) async throws -> Data {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let client = try await BitwardenCipherWriter.initializedClient(
            email: session.accountID,
            userKey: userKey,
            credentials: credentials,
            organizationKeys: organizationKeys
        )
        let folder = try client.vault().folders().encrypt(
            folder: FolderView(id: id, name: name, revisionDate: Date())
        )
        return try bitwardenEncoder.encode(FolderWriteRequestDTO(name: folder.name))
    }

    func deleteFolder(id: String, session: AuthenticatedSession) async throws {
        _ = try await authenticatedResponse(
            session: session,
            method: "DELETE",
            path: "api/folders/\(id)"
        )
    }

    func createTextSend(
        item: SendItem,
        password: String?,
        session: AuthenticatedSession
    ) async throws {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference) else {
            throw VaultwardenServiceError.vaultLocked
        }
        let prepared = try await BitwardenCipherWriter.encryptTextSendPrepared(
            item: item,
            password: password,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials
        )
        let passwordOverride = try Self.sendAccessPassword(
            password,
            sendKeyBase64URL: try prepared.client.sends().decrypt(send: prepared.send).key
        )
        let body = try bitwardenEncoder.encode(
            SendWriteRequestDTO(prepared.send, passwordOverride: passwordOverride)
        )
        _ = try await authenticatedResponse(session: session, method: "POST", path: "api/sends", body: body)
    }

    func updateSend(
        item: SendItem,
        existing: RemoteSendState,
        session: AuthenticatedSession
    ) async throws {
        let credentials = try sessionStore.load(reference: session.tokenReference)
        guard let userKey = await keyMemory.load(reference: session.tokenReference),
              let id = existing.view.id else {
            throw VaultwardenServiceError.vaultLocked
        }
        let send = try await BitwardenCipherWriter.encryptUpdatedSend(
            item: item,
            existing: existing.view,
            passwordUpdate: .preserve,
            email: session.accountID,
            userKey: userKey,
            credentials: credentials
        )
        let body = try bitwardenEncoder.encode(SendWriteRequestDTO(send))
        _ = try await authenticatedResponse(
            session: session,
            method: "PUT",
            path: "api/sends/\(id)",
            body: body
        )
    }

    func deleteSend(id: UUID, session: AuthenticatedSession) async throws {
        _ = try await authenticatedResponse(
            session: session,
            method: "DELETE",
            path: "api/sends/\(id.uuidString.lowercased())"
        )
    }

    private func authenticatedResponse(
        session: AuthenticatedSession,
        method: String,
        path: String,
        body: Data? = nil,
        requestID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var credentials = try sessionStore.load(reference: session.tokenReference)
        if credentials.expiresAt <= Date().addingTimeInterval(30) {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
        }
        var result = try await authorizedResponse(
            baseURL: session.serverURL,
            credentials: credentials,
            method: method,
            path: path,
            body: body,
            requestID: requestID
        )
        if result.1.statusCode == 401 {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
            result = try await authorizedResponse(
                baseURL: session.serverURL,
                credentials: credentials,
                method: method,
                path: path,
                body: body,
                requestID: requestID
            )
        }
        try validate(response: result.1, data: result.0)
        return result
    }

    private func authenticatedUploadResponse(
        session: AuthenticatedSession,
        method: String,
        path: String,
        fileURL: URL,
        contentType: String
    ) async throws -> (Data, HTTPURLResponse) {
        var credentials = try sessionStore.load(reference: session.tokenReference)
        if credentials.expiresAt <= Date().addingTimeInterval(30) {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
        }
        func upload(_ credentials: StoredSessionCredentials) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: endpoint(session.serverURL, path: path))
            request.httpMethod = method
            request.setValue("\(credentials.tokenType) \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            applyCommonHeaders(to: &request)
            return try await httpClient.upload(for: request, fromFile: fileURL)
        }
        var result = try await upload(credentials)
        if result.1.statusCode == 401 {
            credentials = try await refreshCredentials(
                baseURL: session.serverURL,
                current: credentials,
                reference: session.tokenReference
            )
            result = try await upload(credentials)
        }
        try validate(response: result.1, data: result.0)
        return result
    }

    private func makeMultipartFile(
        encryptedFileURL: URL,
        fileName: String,
        directory: URL
    ) throws -> (url: URL, boundary: String) {
        let boundary = "VaultwardenBoundary-\(UUID().uuidString)"
        let multipartURL = directory.appendingPathComponent("multipart.body")
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: multipartURL)
        defer { try? output.close() }
        let escapedName = fileName.replacingOccurrences(of: "\"", with: "_")
        try output.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(escapedName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
        ))
        let input = try FileHandle(forReadingFrom: encryptedFileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return (multipartURL, boundary)
    }

    private static func directUploadPath(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.hasPrefix("api/") ? normalized : "api/\(normalized)"
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = value.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Send file" : name
    }

    private func authorizedResponse(
        baseURL: URL,
        credentials: StoredSessionCredentials,
        method: String,
        path: String,
        body: Data?,
        requestID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint(baseURL, path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("\(credentials.tokenType) \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let requestID {
            // Stable across token refresh and retry. Vaultwarden/proxies that support
            // idempotency can suppress a duplicate POST after a lost response.
            request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key")
            request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        }
        applyCommonHeaders(to: &request)
        return try await httpClient.data(for: request)
    }

    private var bitwardenEncoder: JSONEncoder {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private static let serverDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let serverDateFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseServerDate(_ value: String) -> Date? {
        serverDateFormatter.date(from: value)
            ?? serverDateFormatterWithoutFractionalSeconds.date(from: value)
    }

    private func refreshCredentials(
        baseURL: URL,
        current: StoredSessionCredentials,
        reference: String
    ) async throws -> StoredSessionCredentials {
        guard let refreshToken = current.refreshToken else {
            throw VaultwardenServiceError.sessionExpired
        }
        var request = URLRequest(url: endpoint(baseURL, path: "identity/connect/token"))
        request.httpMethod = "POST"
        request.httpBody = FormURLEncoder.encode([
            ("grant_type", "refresh_token"),
            ("client_id", ClientPlatform.clientID),
            ("refresh_token", refreshToken)
        ])
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        let (data, response) = try await httpClient.data(for: request)
        try validate(response: response, data: data)
        let token = try decodeTokenResponse(data)
        let refreshed = StoredSessionCredentials(
            userID: current.userID ?? token.userID,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? current.refreshToken,
            tokenType: token.tokenType,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
            protectedUserKey: token.protectedUserKey ?? current.protectedUserKey,
            protectedPrivateKey: token.protectedPrivateKey ?? current.protectedPrivateKey,
            kdf: current.kdf,
            accountKeys: current.accountKeys
        )
        try sessionStore.save(refreshed, reference: reference)
        return refreshed
    }

    private func preLogin(baseURL: URL, email: String) async throws -> KDFConfiguration {
        var request = URLRequest(url: endpoint(baseURL, path: "identity/accounts/prelogin"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(PreLoginRequestDTO(email: email))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        let (data, response) = try await httpClient.data(for: request)
        try validate(response: response, data: data)
        guard let result = try? BitwardenJSONDecoder.make().decode(PreLoginResponseDTO.self, from: data) else {
            throw VaultwardenServiceError.invalidResponse
        }
        return result.configuration
    }

    private func requestPasswordToken(
        baseURL: URL,
        email: String,
        authenticationHash: String,
        twoFactorCode: String?
    ) async throws -> IdentityTokenResponseDTO {
        var request = URLRequest(url: endpoint(baseURL, path: "identity/connect/token"))
        request.httpMethod = "POST"
        var fields = [
            ("scope", "api offline_access"),
            ("client_id", ClientPlatform.clientID),
            ("deeplinkScheme", "https"),
            ("deviceType", ClientPlatform.deviceType),
            ("deviceIdentifier", deviceIdentifier),
            ("deviceName", ClientPlatform.deviceName),
            ("grant_type", "password"),
            ("username", email),
            ("password", authenticationHash)
        ]
        if let twoFactorCode, !twoFactorCode.isEmpty {
            fields.append(("twoFactorProvider", "0"))
            fields.append(("twoFactorToken", twoFactorCode))
            fields.append(("twoFactorRemember", "0"))
        }
        request.httpBody = FormURLEncoder.encode(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if body.contains("twofactor") || body.contains("two-factor") || body.contains("two factor") {
                throw VaultwardenServiceError.twoFactorRequired
            }
            try validate(response: response, data: data)
            throw VaultwardenServiceError.invalidResponse
        }
        return try decodeTokenResponse(data)
    }

    private func decodeTokenResponse(_ data: Data) throws -> IdentityTokenResponseDTO {
        do {
            return try BitwardenJSONDecoder.make().decode(IdentityTokenResponseDTO.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw VaultwardenServiceError.invalidTokenResponse(field: key.stringValue)
        } catch let DecodingError.typeMismatch(_, context) {
            throw VaultwardenServiceError.invalidTokenResponse(
                field: context.codingPath.last?.stringValue ?? "unknown"
            )
        } catch let DecodingError.valueNotFound(_, context) {
            throw VaultwardenServiceError.invalidTokenResponse(
                field: context.codingPath.last?.stringValue ?? "unknown"
            )
        } catch {
            throw VaultwardenServiceError.invalidResponse
        }
    }

    private func validatedBaseURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https" else {
            throw VaultwardenServiceError.insecureTransport
        }
        guard url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw VaultwardenServiceError.invalidServerURL
        }
        return url
    }

    private func endpoint(_ baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClientPlatform.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let identityError = try? JSONDecoder().decode(IdentityErrorDTO.self, from: data)
            let message = identityError?.message ?? identityError?.errorDescription ?? identityError?.error
            throw VaultwardenServiceError.serverRejected(status: response.statusCode, message: message)
        }
    }

    private var deviceIdentifier: String {
        let key = "vaultwardenApp.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private func sessionReference(baseURL: URL, email: String) -> String {
        Data("\(baseURL.absoluteString)|\(email)".utf8).base64EncodedString()
    }
}

nonisolated private struct FileSendUploadResponseDTO: Decodable {
    let fileUploadType: Int
    let url: String
    let sendResponse: SendResponseIdentityDTO?

    var sendIDFromPath: String? {
        let parts = url.split(separator: "/")
        guard let sendsIndex = parts.firstIndex(of: "sends"), parts.indices.contains(sendsIndex + 1) else { return nil }
        return String(parts[sendsIndex + 1])
    }
}

nonisolated private struct SendResponseIdentityDTO: Decodable {
    let id: String
}

nonisolated private struct SendFileAccessRequestDTO: Encodable {
    let password: String?
}

nonisolated private struct SendFileDownloadResponseDTO: Decodable {
    let url: String
}
