import AuthenticationServices
import BitwardenSdk
import Foundation

nonisolated enum AutoFillVaultPublisher {
    static func publish(
        snapshot: DecryptedVaultSnapshot,
        userKey: Data,
        accountReference: String,
        email: String,
        serverURL: URL,
        credentials sessionCredentials: StoredSessionCredentials
    ) async {
        let records = snapshot.items.compactMap { item -> AutoFillCredentialRecord? in
            guard !item.isDeleted,
                  item.type == .login,
                  snapshot.remoteCiphers[item.id]?.canViewPassword != false,
                  !item.password.isEmpty || item.totpSecret?.isEmpty == false else {
                return nil
            }
            let uriRules = snapshot.remoteCiphers[item.id]?.view.login?.uris?.compactMap { value -> AutoFillURIRule? in
                guard let uri = value.uri?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !uri.isEmpty else { return nil }
                return AutoFillURIRule(
                    uri: uri,
                    match: value.match.flatMap { AutoFillURIMatchType(rawValue: $0.rawValue) }
                )
            }
            let primaryURI = uriRules?.first?.uri ?? item.uri
            return AutoFillCredentialRecord(
                id: item.id.uuidString.lowercased(),
                name: item.name,
                username: item.username,
                password: item.password,
                serviceIdentifier: normalizedServiceIdentifier(primaryURI),
                totpSecret: item.totpSecret,
                uriRules: uriRules
            )
        }
        let passkeyCiphers = snapshot.remoteCiphers.values
            .map(\.view)
            .filter { $0.deletedDate == nil && $0.login?.fido2Credentials?.isEmpty == false }
        let passkeyTargets = snapshot.items.compactMap { item -> AutoFillPasskeyTarget? in
            guard !item.isDeleted, item.type == .login,
                  let view = snapshot.remoteCiphers[item.id]?.view,
                  view.organizationId == nil, view.edit,
                  view.attachments?.isEmpty != false,
                  view.passwordHistory?.isEmpty != false,
                  let uris = view.login?.uris?.compactMap({ value -> AutoFillURIRule? in
                      guard let uri = value.uri, !uri.isEmpty else { return nil }
                      return AutoFillURIRule(
                          uri: uri,
                          match: value.match.flatMap { AutoFillURIMatchType(rawValue: $0.rawValue) }
                      )
                  }), !uris.isEmpty else { return nil }
            return AutoFillPasskeyTarget(
                id: item.id.uuidString.lowercased(), name: item.name,
                username: item.username, uriRules: uris
            )
        }
        var passkeys: [AutoFillPasskeyRecord] = []
        if let client = try? await BitwardenCipherWriter.initializedClient(
            email: email,
            userKey: userKey,
            credentials: sessionCredentials,
            organizationKeys: snapshot.organizationKeys
        ) {
            for cipher in passkeyCiphers {
                let views = (try? client.platform().fido2()
                    .decryptFido2AutofillCredentials(cipherView: cipher)) ?? []
                passkeys.append(contentsOf: views.map {
                    AutoFillPasskeyRecord(
                        cipherID: $0.cipherId,
                        relyingPartyIdentifier: $0.rpId,
                        userName: $0.userNameForUi ?? cipher.login?.username ?? "",
                        credentialID: $0.credentialId,
                        userHandle: $0.userHandle,
                        hasCounter: $0.hasCounter
                    )
                })
            }
        }
        let cryptoContext = makeCryptoContext(
            email: email,
            credentials: sessionCredentials,
            organizationKeys: snapshot.organizationKeys
        )
        let payload = AutoFillVaultPayload(
            schemaVersion: 4,
            accountReference: accountReference,
            generatedAt: Date(),
            credentials: records,
            passkeys: passkeys,
            passkeyCiphers: passkeyCiphers.map { AutoFillPasskeyCipherRecord(view: $0) },
            cryptoContext: cryptoContext,
            writeSession: AutoFillWriteSession(
                serverURL: serverURL,
                accessToken: sessionCredentials.accessToken,
                refreshToken: sessionCredentials.refreshToken,
                tokenType: sessionCredentials.tokenType,
                expiresAt: sessionCredentials.expiresAt
            ),
            userKey: userKey,
            folders: snapshot.folderIDsByName.map { name, id in
                AutoFillFolderRecord(id: id, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            passkeyTargets: passkeyTargets
        )
        do {
            try AutoFillSharedVault.publish(payload: payload, userKey: userKey)
            try await replaceCredentialIdentities(payload)
            SecureLog.event("AutoFill index published", logger: SecureLog.autofill)
        } catch {
            SecureLog.failure("AutoFill index publication", error: error, logger: SecureLog.autofill)
        }
    }

    static func clear(accountReference: String) async {
        try? AutoFillSharedVault.clear(reference: accountReference)
        try? await ASCredentialIdentityStore.shared.removeAllCredentialIdentities()
    }

    private static func replaceCredentialIdentities(_ payload: AutoFillVaultPayload) async throws {
        var identities = payload.credentials.reduce(into: [any ASCredentialIdentity]()) { values, record in
            guard let serviceValue = record.serviceIdentifier else { return }
            let service = ASCredentialServiceIdentifier(identifier: serviceValue, type: .domain)
            if !record.password.isEmpty {
                let identity = ASPasswordCredentialIdentity(
                    serviceIdentifier: service,
                    user: record.username,
                    recordIdentifier: "password|\(record.id)"
                )
                identity.rank = 100
                values.append(identity)
            }
            if record.totpSecret?.isEmpty == false {
                values.append(ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: service,
                    label: record.name,
                    recordIdentifier: "totp|\(record.id)"
                ))
            }
        }
        if #available(iOS 17.0, *) {
            identities.append(contentsOf: (payload.passkeys ?? []).map { passkey in
                ASPasskeyCredentialIdentity(
                    relyingPartyIdentifier: passkey.relyingPartyIdentifier,
                    userName: passkey.userName,
                    credentialID: passkey.credentialID,
                    userHandle: passkey.userHandle,
                    recordIdentifier: passkey.cipherID
                )
            })
        }
        try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    private static func makeCryptoContext(
        email: String,
        credentials: StoredSessionCredentials,
        organizationKeys: [String: String]
    ) -> AutoFillCryptoContext? {
        guard let kdf = credentials.kdf, let keys = credentials.accountKeys else { return nil }
        return AutoFillCryptoContext(
            userID: credentials.userID,
            email: email,
            kdfType: kdf.type.rawValue,
            iterations: kdf.iterations,
            memory: kdf.memory,
            parallelism: kdf.parallelism,
            privateKey: keys.privateKey,
            signedPublicKey: keys.signedPublicKey,
            signingKey: keys.signingKey,
            securityState: keys.securityState,
            organizationKeys: organizationKeys
        )
    }

    private static func normalizedServiceIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URL(string: trimmed)?.host?.lowercased() { return host }
        return URL(string: "https://\(trimmed)")?.host?.lowercased()
    }
}
