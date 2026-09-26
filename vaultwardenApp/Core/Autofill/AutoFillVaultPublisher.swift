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
                  snapshot.remoteCiphers[item.id]?.canViewPassword != false else {
                return nil
            }
            let fields = insertableFields(for: item)
            guard item.type != .login || !item.password.isEmpty
                    || item.totpSecret?.isEmpty == false || !item.username.isEmpty
                    || !fields.isEmpty else { return nil }
            guard item.type == .login || !fields.isEmpty else { return nil }
            let uriRules = snapshot.remoteCiphers[item.id]?.view.login?.uris?.compactMap { value -> AutoFillURIRule? in
                guard let uri = value.uri?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !uri.isEmpty else { return nil }
                return AutoFillURIRule(
                    uri: uri,
                    match: value.match.flatMap { AutoFillURIMatchType(rawValue: $0.rawValue) }
                )
            }
            let primaryURI = item.type == .login ? (uriRules?.first?.uri ?? item.uri) : ""
            return AutoFillCredentialRecord(
                id: item.id.uuidString.lowercased(),
                name: item.name,
                username: item.type == .login ? item.username : "",
                password: item.type == .login ? item.password : "",
                serviceIdentifier: normalizedServiceIdentifier(primaryURI),
                totpSecret: item.type == .login ? item.totpSecret : nil,
                uriRules: uriRules,
                itemType: AutoFillItemType(rawValue: item.type.rawValue),
                insertableFields: fields
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
            guard record.isLogin else { return }
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

    private static func insertableFields(for item: VaultItem) -> [AutoFillTextField] {
        var fields: [AutoFillTextField] = []
        var section = ""
        func add(_ title: String, _ value: String, symbol: String,
                 sensitive: Bool = false, custom: Bool = false) {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.isEmpty else { return }
            fields.append(AutoFillTextField(
                id: "field|\(fields.count)", title: title, value: value, symbol: symbol,
                section: section, isSensitive: sensitive, isCustom: custom
            ))
        }

        switch item.type {
        case .login:
            section = "Websites (URI)"
            for (index, uri) in item.websiteURIs.enumerated() {
                add(index == 0 ? "Website URI" : "Website URI \(index + 1)", uri, symbol: "link")
            }
        case .secureNote:
            break
        case .card:
            section = "Card"
            if let card = item.card {
                add("Cardholder", card.cardholderName, symbol: "person")
                add("Number", card.number, symbol: "creditcard", sensitive: true)
                add("Security code", card.securityCode, symbol: "lock", sensitive: true)
            }
        case .identity:
            if let identity = item.identity {
                section = "Personal Information"
                add("Full name", identity.fullName, symbol: "person")
                add("Username", identity.username, symbol: "person")
                add("Company", identity.company, symbol: "building.2")
                section = "Contact"
                add("Email", identity.email, symbol: "envelope")
                add("Phone", identity.phone, symbol: "phone")
                section = "Identification"
                add("Social security number", identity.socialSecurityNumber, symbol: "number", sensitive: true)
                add("Passport number", identity.passportNumber, symbol: "number")
                add("License number", identity.licenseNumber, symbol: "number")
                section = "Address"
                add("Address line 1", identity.address1, symbol: "house")
                add("Address line 2", identity.address2, symbol: "house")
                add("City", identity.city, symbol: "mappin")
                add("State / Province", identity.state, symbol: "mappin")
                add("Postal code", identity.postalCode, symbol: "number")
                add("Country", identity.country, symbol: "globe")
            }
        case .sshKey:
            section = "SSH Key"
            add("Public key", item.username, symbol: "key")
            add("Private key", item.password, symbol: "key.fill", sensitive: true)
        }

        section = "Notes"
        add(item.type == .sshKey ? "Notes / Fingerprint" : "Notes", item.notes, symbol: "note.text")
        section = "Custom Fields"
        for field in item.customFields where field.type != .boolean {
            let value = field.type == .linked
                ? (field.value == "password" ? item.password : item.username)
                : field.value
            add(field.name, value, symbol: field.type.icon,
                sensitive: field.type == .hidden || (field.type == .linked && field.value == "password"),
                custom: true)
        }
        return fields
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
