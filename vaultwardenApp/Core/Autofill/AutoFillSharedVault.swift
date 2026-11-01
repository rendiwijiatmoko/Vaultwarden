import CryptoKit
import BitwardenSdk
import Foundation
import LocalAuthentication
import Security

/// Shared app/extension policy. Missing policy fails closed, including before the
/// app has been opened after an upgrade. Keychain ACLs enforce the same policy.
nonisolated enum DeviceUnlockPolicy: String, Sendable {
    case disabled, biometrics, biometricsOrPasscode

    init(biometricsEnabled: Bool, passcodeFallback: Bool) {
        self = !biometricsEnabled ? .disabled : (passcodeFallback ? .biometricsOrPasscode : .biometrics)
    }

    var accessControlFlags: SecAccessControlCreateFlags {
        self == .biometricsOrPasscode ? .userPresence : .biometryCurrentSet
    }

    var authenticationPolicy: LAPolicy {
        self == .biometricsOrPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
    }

    static let storageKey = "security.deviceUnlockPolicy.v2"
    private static let lock = NSRecursiveLock()

    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static var current: Self {
        withLock {
            UserDefaults(suiteName: AutoFillSharedVault.appGroupIdentifier)?
                .string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .disabled
        }
    }

    /// Revoke old keys before enabling a changed policy. A failure leaves device
    /// unlock disabled; the master password remains available.
    static func configure(_ policy: Self) throws {
        try withLock {
            guard let defaults = UserDefaults(suiteName: AutoFillSharedVault.appGroupIdentifier) else {
                throw AutoFillSharedVaultError.appGroupUnavailable
            }
            let changed = current != policy
            defaults.set(Self.disabled.rawValue, forKey: storageKey)
            let legacyServices = [
                "xyz.0xmwehehe.vaultwardenApp.session.vault-key",
                "xyz.0xmwehehe.vaultwardenApp.autofill.payload-key"
            ]
            let services = legacyServices + (changed || policy == .disabled
                ? [AutoFillSharedVault.vaultKeyService, AutoFillSharedVault.payloadKeyService] : [])
            var cleanupFailure: OSStatus?
            for service in services {
                for shared in [true, false] {
                    var query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service
                    ]
                    if shared { query[kSecAttrAccessGroup as String] = AutoFillSharedVault.keychainAccessGroup }
                    #if os(macOS)
                    query[kSecUseDataProtectionKeychain as String] = true
                    #endif
                    let status = SecItemDelete(query as CFDictionary)
                    if status != errSecSuccess && status != errSecItemNotFound {
                        cleanupFailure = status
                    }
                }
            }
            if let cleanupFailure { throw AutoFillSharedVaultError.keychain(cleanupFailure) }
            defaults.set(policy.rawValue, forKey: storageKey)
        }
    }

    func makeAccessControl() throws -> SecAccessControl {
        guard self != .disabled else { throw AutoFillSharedVaultError.vaultUnavailable }
        #if os(macOS)
        let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        let accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, accessibility, accessControlFlags, &error) else {
            throw AutoFillSharedVaultError.authenticationFailed
        }
        return control
    }
}

/// A specific keyboard suggestion, retained while the shared vault authenticates.
/// A selection with a missing/invalid identity must fail, never become a list request.
nonisolated enum AutoFillCredentialSelection: Sendable {
    case password(recordIdentifier: String?)
    case oneTimeCode(recordIdentifier: String?)

    func resolve(in credentials: [AutoFillCredentialRecord]) -> AutoFillCredentialRecord? {
        let identifier: String?
        let prefix: String
        switch self {
        case let .password(recordIdentifier):
            identifier = recordIdentifier
            prefix = "password"
        case let .oneTimeCode(recordIdentifier):
            identifier = recordIdentifier
            prefix = "totp"
        }
        guard let identifier, !identifier.isEmpty else { return nil }
        let components = identifier.split(separator: "|", omittingEmptySubsequences: false)
        let recordID: String
        if components.count == 1 {
            // Accept unprefixed record IDs as well as the published typed identities.
            recordID = identifier
        } else {
            guard components.count == 2, components[0] == prefix,
                  !components[1].isEmpty else { return nil }
            recordID = String(components[1])
        }
        guard let record = credentials.first(where: { $0.id == recordID }),
              record.isLogin else { return nil }
        switch self {
        case .password:
            return record.password.isEmpty ? nil : record
        case .oneTimeCode:
            return record.totpSecret?.isEmpty == false ? record : nil
        }
    }
}

nonisolated enum AutoFillURIMatchType: UInt8, Codable, Hashable, Sendable {
    case baseDomain = 0
    case host = 1
    case startsWith = 2
    case exact = 3
    case regularExpression = 4
    case never = 5

    static let defaultChoices: [Self] = [.baseDomain, .host, .exact, .never]

    var title: String {
        let key: String = switch self {
        case .baseDomain: "Base Domain"
        case .host: "Host"
        case .startsWith: "Starts With"
        case .exact: "Exact"
        case .regularExpression: "Regular Expression"
        case .never: "Never"
        }
        return L10n.string(key)
    }
}

nonisolated struct AutoFillURIRule: Codable, Hashable, Sendable {
    let uri: String
    /// A missing value uses Bitwarden's default: Base Domain.
    let match: AutoFillURIMatchType?
}

nonisolated enum AutoFillCredentialMatch: Int, Hashable, Sendable, Comparable {
    case baseDomain = 100
    case regularExpression = 200
    case host = 300
    case startsWith = 400
    case exact = 500

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        let key: String = switch self {
        case .baseDomain: "Base Domain"
        case .regularExpression: "Regular Expression"
        case .host: "Host"
        case .startsWith: "Starts With"
        case .exact: "Exact"
        }
        return L10n.string(key)
    }
}

nonisolated struct AutoFillCredentialRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let username: String
    let password: String
    let serviceIdentifier: String?
    let totpSecret: String?
    let uriRules: [AutoFillURIRule]?
    let itemType: AutoFillItemType?
    let insertableFields: [AutoFillTextField]?

    var isLogin: Bool { itemType == nil || itemType == .login }
    var hasInsertableText: Bool {
        (isLogin && (!username.isEmpty || !password.isEmpty || totpSecret?.isEmpty == false))
            || insertableFields?.isEmpty == false
    }

    init(
        id: String,
        name: String,
        username: String,
        password: String,
        serviceIdentifier: String?,
        totpSecret: String?,
        uriRules: [AutoFillURIRule]? = nil,
        itemType: AutoFillItemType? = nil,
        insertableFields: [AutoFillTextField]? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.password = password
        self.serviceIdentifier = serviceIdentifier
        self.totpSecret = totpSecret
        self.uriRules = uriRules
        self.itemType = itemType
        self.insertableFields = insertableFields
    }

    func matches(
        serviceIdentifiers: [String],
        defaultMatchType: AutoFillURIMatchType = .baseDomain
    ) -> Bool {
        guard !serviceIdentifiers.isEmpty else { return true }
        return bestMatch(
            serviceIdentifiers: serviceIdentifiers,
            defaultMatchType: defaultMatchType
        ) != nil
    }

    func bestMatch(
        serviceIdentifiers: [String],
        defaultMatchType: AutoFillURIMatchType = .baseDomain
    ) -> AutoFillCredentialMatch? {
        let activeRules: [AutoFillURIRule]
        if let uriRules, !uriRules.isEmpty {
            activeRules = uriRules
        } else if let serviceIdentifier {
            activeRules = [AutoFillURIRule(uri: serviceIdentifier, match: nil)]
        } else {
            return nil
        }

        return activeRules.compactMap { rule in
            serviceIdentifiers.compactMap { requested in
                Self.match(rule: rule, requested: requested, defaultMatchType: defaultMatchType)
            }.max()
        }.max()
    }

    private static func match(
        rule: AutoFillURIRule,
        requested: String,
        defaultMatchType: AutoFillURIMatchType
    ) -> AutoFillCredentialMatch? {
        let saved = rule.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty, !candidate.isEmpty else { return nil }

        switch rule.match ?? defaultMatchType {
        case .baseDomain:
            guard let savedHost = normalizedHost(saved),
                  let requestedHost = normalizedHost(candidate),
                  registrableDomain(savedHost) == registrableDomain(requestedHost) else { return nil }
            return .baseDomain
        case .host:
            guard let savedResource = resource(saved),
                  let requestedResource = resource(candidate),
                  savedResource.host == requestedResource.host else { return nil }
            if let savedPort = savedResource.port, savedPort != requestedResource.port { return nil }
            return .host
        case .startsWith:
            return candidate.lowercased().hasPrefix(saved.lowercased()) ? .startsWith : nil
        case .exact:
            return candidate.caseInsensitiveCompare(saved) == .orderedSame ? .exact : nil
        case .regularExpression:
            guard let expression = try? NSRegularExpression(pattern: saved, options: [.caseInsensitive]) else {
                return nil
            }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            return expression.firstMatch(in: candidate, range: range) == nil ? nil : .regularExpression
        case .never:
            return nil
        }
    }

    private static func resource(_ value: String) -> (host: String, port: Int?)? {
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        return (host, components.port)
    }

    private static func normalizedHost(_ value: String) -> String? {
        resource(value)?.host
    }

    private static func registrableDomain(_ host: String) -> String {
        if isIPAddress(host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let twoLabelSuffix = labels.suffix(2).joined(separator: ".")
        if commonTwoLabelPublicSuffixes.contains(twoLabelSuffix), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let components = host.split(separator: ".")
        return components.count == 4 && components.allSatisfy {
            guard let number = Int($0) else { return false }
            return (0...255).contains(number)
        }
    }

    private static let commonTwoLabelPublicSuffixes: Set<String> = [
        "ac.id", "co.id", "go.id", "or.id", "sch.id", "web.id",
        "ac.uk", "co.uk", "gov.uk", "org.uk",
        "com.au", "net.au", "org.au", "edu.au",
        "co.jp", "ne.jp", "or.jp", "co.kr", "com.br", "com.cn",
        "com.hk", "com.mx", "com.my", "com.ph", "com.sg", "com.tr",
        "co.in", "co.nz", "co.za"
    ]
}

nonisolated enum AutoFillItemType: String, Codable, Hashable, Sendable {
    case login = "Login"
    case secureNote = "Secure Note"
    case card = "Card"
    case identity = "Identity"
    case sshKey = "SSH Key"

    var localizedTitle: String { L10n.string(rawValue) }

    var icon: String {
        switch self {
        case .login: "key.fill"
        case .secureNote: "note.text"
        case .card: "creditcard.fill"
        case .identity: "person.text.rectangle.fill"
        case .sshKey: "terminal.fill"
        }
    }
}

nonisolated struct AutoFillTextField: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let symbol: String
    let section: String?
    let isSensitive: Bool?
    let isCustom: Bool?

    init(id: String, title: String, value: String, symbol: String,
         section: String? = nil, isSensitive: Bool = false, isCustom: Bool = false) {
        self.id = id
        self.title = title
        self.value = value
        self.symbol = symbol
        self.section = section
        self.isSensitive = isSensitive
        self.isCustom = isCustom
    }
}

nonisolated struct AutoFillVaultPayload: Codable, Sendable {
    let schemaVersion: Int
    let accountReference: String
    let generatedAt: Date
    let credentials: [AutoFillCredentialRecord]
    let passkeys: [AutoFillPasskeyRecord]?
    let passkeyCiphers: [AutoFillPasskeyCipherRecord]?
    let cryptoContext: AutoFillCryptoContext?
    let writeSession: AutoFillWriteSession?
    let userKey: Data?
    let folders: [AutoFillFolderRecord]?
    let passkeyTargets: [AutoFillPasskeyTarget]?
}

nonisolated struct AutoFillPasskeyTarget: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let username: String
    let uriRules: [AutoFillURIRule]

    func matches(_ relyingPartyIdentifier: String) -> Bool {
        let domainRules = uriRules
            .filter { $0.match != .never }
            .map { AutoFillURIRule(uri: $0.uri, match: .baseDomain) }
        return AutoFillCredentialRecord(
            id: id, name: name, username: username, password: "",
            serviceIdentifier: nil, totpSecret: nil, uriRules: domainRules
        ).matches(serviceIdentifiers: [relyingPartyIdentifier])
    }
}

nonisolated struct AutoFillFolderRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

nonisolated struct AutoFillUnlockedVault: Sendable {
    let payload: AutoFillVaultPayload
    let userKey: Data
}

nonisolated struct AutoFillPasskeyRecord: Codable, Hashable, Sendable {
    let cipherID: String
    let relyingPartyIdentifier: String
    let userName: String
    let credentialID: Data
    let userHandle: Data
    let hasCounter: Bool
}

nonisolated struct AutoFillCryptoContext: Codable, Sendable {
    let userID: String?
    let email: String
    let kdfType: Int
    let iterations: Int
    let memory: Int?
    let parallelism: Int?
    let privateKey: String
    let signedPublicKey: String?
    let signingKey: String?
    let securityState: String?
    let organizationKeys: [String: String]
}

nonisolated struct AutoFillWriteSession: Codable, Sendable {
    let serverURL: URL
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date
}

nonisolated struct AutoFillPasskeyCipherRecord: Codable, Sendable {
    let id: String
    let organizationID: String?
    let folderID: String?
    let collectionIDs: [String]
    let key: String?
    let name: String
    let username: String?
    let credentials: [AutoFillFido2Credential]
    let favorite: Bool
    let reprompt: UInt8
    let organizationUseTotp: Bool
    let edit: Bool
    let viewPassword: Bool
    let creationDate: Date
    let deletedDate: Date?
    let revisionDate: Date
    let archivedDate: Date?

    init(view: CipherView, identifier: String? = nil) {
        id = identifier ?? view.id ?? ""
        organizationID = view.organizationId
        folderID = view.folderId
        collectionIDs = view.collectionIds
        key = view.key
        name = view.name
        username = view.login?.username
        credentials = (view.login?.fido2Credentials ?? []).map(AutoFillFido2Credential.init)
        favorite = view.favorite
        reprompt = view.reprompt.rawValue
        organizationUseTotp = view.organizationUseTotp
        edit = view.edit
        viewPassword = view.viewPassword
        creationDate = view.creationDate
        deletedDate = view.deletedDate
        revisionDate = view.revisionDate
        archivedDate = view.archivedDate
    }

    var sdkView: CipherView {
        CipherView(
            id: id,
            organizationId: organizationID,
            folderId: folderID,
            collectionIds: collectionIDs,
            key: key,
            name: name,
            notes: nil,
            type: .login,
            login: LoginView(
                username: username,
                password: nil,
                passwordRevisionDate: nil,
                uris: nil,
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: credentials.map(\.sdkCredential)
            ),
            identity: nil,
            card: nil,
            secureNote: nil,
            sshKey: nil,
            bankAccount: nil,
            driversLicense: nil,
            passport: nil,
            favorite: favorite,
            reprompt: CipherRepromptType(rawValue: reprompt) ?? .none,
            organizationUseTotp: organizationUseTotp,
            edit: edit,
            permissions: nil,
            viewPassword: viewPassword,
            localData: nil,
            attachments: nil,
            attachmentDecryptionFailures: nil,
            fields: nil,
            passwordHistory: nil,
            creationDate: creationDate,
            deletedDate: deletedDate,
            revisionDate: revisionDate,
            archivedDate: archivedDate
        )
    }
}

nonisolated struct AutoFillFido2Credential: Codable, Sendable {
    let credentialID: String
    let keyType: String
    let keyAlgorithm: String
    let keyCurve: String
    let keyValue: String
    let rpID: String
    let userHandle: String?
    let userName: String?
    let counter: String
    let rpName: String?
    let userDisplayName: String?
    let discoverable: String
    let creationDate: Date

    init(_ value: Fido2Credential) {
        credentialID = value.credentialId
        keyType = value.keyType
        keyAlgorithm = value.keyAlgorithm
        keyCurve = value.keyCurve
        keyValue = value.keyValue
        rpID = value.rpId
        userHandle = value.userHandle
        userName = value.userName
        counter = value.counter
        rpName = value.rpName
        userDisplayName = value.userDisplayName
        discoverable = value.discoverable
        creationDate = value.creationDate
    }

    var sdkCredential: Fido2Credential {
        Fido2Credential(
            credentialId: credentialID,
            keyType: keyType,
            keyAlgorithm: keyAlgorithm,
            keyCurve: keyCurve,
            keyValue: keyValue,
            rpId: rpID,
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

nonisolated enum AutoFillSharedVaultError: LocalizedError {
    case appGroupUnavailable
    case vaultUnavailable
    case invalidVaultKey
    case invalidPayload
    case authenticationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: L10n.string("The shared AutoFill container is unavailable.")
        case .vaultUnavailable: L10n.string("Open the main app and sync your vault before using AutoFill.")
        case .invalidVaultKey: L10n.string("The shared vault key is invalid. Sign in again from the main app.")
        case .invalidPayload: L10n.string("The shared AutoFill vault could not be decrypted. Sync from the main app.")
        case .authenticationFailed: L10n.string("Biometric or device-passcode authentication was not completed.")
        case let .keychain(status): L10n.format("Keychain could not unlock AutoFill (error %d).", status)
        }
    }
}

/// Shared by the app and Credential Provider extension. The App Group file never contains
/// plaintext credentials: it is sealed with a key derived from the vault key and protected by the device-unlock policy.
nonisolated enum AutoFillSharedVault {
    static let appGroupIdentifier = "group.xyz.0xmwehehe.vaultwardenApp"
    static let vaultKeyService = "xyz.0xmwehehe.vaultwardenApp.session.vault-key.v2"
    static let payloadKeyService = "xyz.0xmwehehe.vaultwardenApp.autofill.payload-key.v2"
    static let writeSessionUpdateService = "xyz.0xmwehehe.vaultwardenApp.autofill.write-session-update"
    static let activeReferenceKey = "autofill.activeAccountReference"
    static let publishedAtKey = "autofill.publishedAt"
    static let publishedCountKey = "autofill.publishedCount"
    static let defaultURIMatchTypeKey = "autofill.defaultURIMatchType"
    static let showsWebsiteIconsKey = "autofill.showsWebsiteIcons"

    static var showsWebsiteIcons: Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.object(forKey: showsWebsiteIconsKey) != nil else { return true }
        return defaults.bool(forKey: showsWebsiteIconsKey)
    }

    static func setShowsWebsiteIcons(_ enabled: Bool) {
        UserDefaults(suiteName: appGroupIdentifier)?.set(enabled, forKey: showsWebsiteIconsKey)
    }

    static var websiteIconCacheDirectory: URL {
        let fileManager = FileManager.default
        let root = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("WebsiteIcons", isDirectory: true)
    }

    static func cachedWebsiteIconData(website: String, serverURL: URL) -> Data? {
        guard let host = websiteHost(from: website) else { return nil }
        let key = SHA256.hash(data: Data("\(serverURL.absoluteString)|\(host)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try? Data(
            contentsOf: websiteIconCacheDirectory.appendingPathComponent("\(key).icon")
        )
    }

    private static func websiteHost(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: candidate)?.host?.lowercased()
    }

    static var defaultURIMatchType: AutoFillURIMatchType {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.object(forKey: defaultURIMatchTypeKey) != nil,
              let value = AutoFillURIMatchType(
                rawValue: UInt8(clamping: defaults.integer(forKey: defaultURIMatchTypeKey))
              ),
              Self.isSupportedDefaultMatchType(value) else { return .baseDomain }
        return value
    }

    static func setDefaultURIMatchType(_ value: AutoFillURIMatchType) {
        let resolved = isSupportedDefaultMatchType(value) ? value : .baseDomain
        UserDefaults(suiteName: appGroupIdentifier)?
            .set(Int(resolved.rawValue), forKey: defaultURIMatchTypeKey)
    }

    private static func isSupportedDefaultMatchType(_ value: AutoFillURIMatchType) -> Bool {
        value == .baseDomain || value == .host || value == .exact || value == .never
    }

    static var keychainAccessGroup: String {
        let fallback = "5KQGTJX2K7.xyz.0xmwehehe.vaultwardenApp.shared"
        guard let configured = Bundle.main.object(
            forInfoDictionaryKey: "VaultSharedKeychainAccessGroup"
        ) as? String,
              configured != "xyz.0xmwehehe.vaultwardenApp.shared" else {
            return fallback
        }
        return configured
    }

    static func publish(payload: AutoFillVaultPayload, userKey: Data) throws {
        try DeviceUnlockPolicy.withLock {
            guard DeviceUnlockPolicy.current != .disabled else { throw AutoFillSharedVaultError.vaultUnavailable }
            guard userKey.count == 64 else { throw AutoFillSharedVaultError.invalidVaultKey }
            let data = try JSONEncoder().encode(payload)
            let payloadKey = try storePayloadKey(userKey: userKey, reference: payload.accountReference)
            let key = encryptionKey(keyMaterial: payloadKey, reference: payload.accountReference)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else { throw AutoFillSharedVaultError.invalidPayload }
            #if os(macOS)
            // The payload remains AES-GCM encrypted; data-protection Keychain access
            // and device-owner authentication guard its key on macOS.
            try combined.write(to: try vaultURL(), options: .atomic)
            #else
            try combined.write(to: try vaultURL(), options: [.atomic, .completeFileProtection])
            #endif
            guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
                throw AutoFillSharedVaultError.appGroupUnavailable
            }
            defaults.set(payload.accountReference, forKey: activeReferenceKey)
            defaults.set(payload.generatedAt, forKey: publishedAtKey)
            defaults.set(payload.credentials.filter(\.isLogin).count, forKey: publishedCountKey)
        }
    }

    static func load(reason: String) async throws -> AutoFillUnlockedVault {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let reference = defaults.string(forKey: activeReferenceKey) else {
            throw AutoFillSharedVaultError.vaultUnavailable
        }
        let policy = DeviceUnlockPolicy.current
        guard policy != .disabled else { throw AutoFillSharedVaultError.vaultUnavailable }
        let context = LAContext()
        context.localizedReason = reason
        context.localizedCancelTitle = L10n.string("Cancel")
        #if os(macOS)
        context.localizedFallbackTitle = L10n.string("Use Mac Password")
        #else
        context.localizedFallbackTitle = L10n.string("Use Device Passcode")
        #endif
        if policy != .biometricsOrPasscode { context.localizedFallbackTitle = "" }
        guard context.canEvaluatePolicy(policy.authenticationPolicy, error: nil),
              try await context.evaluatePolicy(
                policy.authenticationPolicy,
                localizedReason: reason
              ) else {
            throw AutoFillSharedVaultError.authenticationFailed
        }
        guard DeviceUnlockPolicy.current == policy else { throw AutoFillSharedVaultError.vaultUnavailable }
        let payloadKey = try loadPayloadKey(reference: reference, context: context)
        let encrypted = try Data(contentsOf: vaultURL())
        let key = encryptionKey(keyMaterial: payloadKey, reference: reference)
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let plaintext = try? AES.GCM.open(box, using: key),
              let payload = try? JSONDecoder().decode(AutoFillVaultPayload.self, from: plaintext),
              payload.schemaVersion == 4,
              payload.accountReference == reference else {
            throw AutoFillSharedVaultError.invalidPayload
        }
        guard let userKey = payload.userKey, userKey.count == 64 else {
            throw AutoFillSharedVaultError.invalidVaultKey
        }
        return AutoFillUnlockedVault(payload: payload, userKey: userKey)
    }

    static func clear(reference: String? = nil) throws {
        let url = try vaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            if reference == nil || defaults.string(forKey: activeReferenceKey) == reference {
                defaults.removeObject(forKey: activeReferenceKey)
                defaults.removeObject(forKey: publishedAtKey)
                defaults.removeObject(forKey: publishedCountKey)
            }
        }
        if let reference {
            SecItemDelete(payloadKeyQuery(reference: reference) as CFDictionary)
            SecItemDelete(writeSessionUpdateQuery(reference: reference) as CFDictionary)
        }
    }

    static func saveWriteSessionUpdate(
        _ session: AutoFillWriteSession,
        reference: String
    ) throws {
        let data = try JSONEncoder().encode(session)
        let lookup = writeSessionUpdateQuery(reference: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = lookup
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AutoFillSharedVaultError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AutoFillSharedVaultError.keychain(updateStatus)
        }
    }

    static func takeWriteSessionUpdate(reference: String) throws -> AutoFillWriteSession? {
        let lookup = writeSessionUpdateQuery(reference: reference)
        var query = lookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AutoFillSharedVaultError.keychain(status) }
        guard let data = result as? Data,
              let session = try? JSONDecoder().decode(AutoFillWriteSession.self, from: data) else {
            throw AutoFillSharedVaultError.invalidPayload
        }
        SecItemDelete(lookup as CFDictionary)
        return session
    }

    static func vaultKeyQuery(reference: String, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultKeyService,
            kSecAttrAccount as String: reference
        ]
        if shared {
            query[kSecAttrAccessGroup as String] = keychainAccessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func loadPayloadKey(reference: String, context: LAContext) throws -> Data {
        var query = payloadKeyQuery(reference: reference)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw AutoFillSharedVaultError.vaultUnavailable }
        guard status == errSecSuccess else { throw AutoFillSharedVaultError.keychain(status) }
        guard let key = result as? Data else { throw AutoFillSharedVaultError.invalidVaultKey }
        return key
    }

    private static func storePayloadKey(userKey: Data, reference: String) throws -> Data {
        // Derive while the vault is already unlocked, so publishing never needs
        // to read an authentication-protected item or display another prompt.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: userKey),
            salt: Data("vaultwarden-autofill-device-key-v2".utf8),
            info: Data(reference.utf8), outputByteCount: 32
        )
        let key = derived.withUnsafeBytes { Data($0) }
        let policy = DeviceUnlockPolicy.current
        let control = try policy.makeAccessControl()
        let status = SecItemDelete(payloadKeyQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AutoFillSharedVaultError.keychain(status)
        }
        var query = payloadKeyQuery(reference: reference)
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = control
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AutoFillSharedVaultError.keychain(addStatus) }
        guard DeviceUnlockPolicy.current == policy else {
            SecItemDelete(payloadKeyQuery(reference: reference) as CFDictionary)
            throw AutoFillSharedVaultError.vaultUnavailable
        }
        return key
    }

    private static func payloadKeyQuery(reference: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: payloadKeyService,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func writeSessionUpdateQuery(reference: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: writeSessionUpdateService,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func vaultURL() throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AutoFillSharedVaultError.appGroupUnavailable
        }
        return root.appendingPathComponent("autofill-vault.bin", isDirectory: false)
    }

    private static func encryptionKey(keyMaterial: Data, reference: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            salt: Data("vaultwarden-autofill-v4".utf8),
            info: Data(reference.utf8),
            outputByteCount: 32
        )
    }
}

nonisolated enum AutoFillTOTP {
    static func code(secret: String, date: Date = Date()) -> String? {
        let configuration = configuration(secret)
        guard let keyData = decodeBase32(configuration.secret) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / Double(configuration.period)).bigEndian
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: keyData)
        let bytes: [UInt8] = switch configuration.algorithm {
        case "SHA256": Array(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case "SHA512": Array(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        default: Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        }
        let offset = Int(bytes.last! & 0x0f)
        let value = (UInt32(bytes[offset] & 0x7f) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let modulus = UInt32(pow(10.0, Double(configuration.digits)))
        return String(format: "%0*u", configuration.digits, value % modulus)
    }

    private static func configuration(_ value: String) -> (secret: String, algorithm: String, digits: Int, period: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: trimmed) else {
            return (trimmed, "SHA1", 6, 30)
        }
        let parameters = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name.lowercased()] = item.value ?? ""
        }
        return (
            parameters["secret"] ?? "",
            (parameters["algorithm"] ?? "SHA1").uppercased(),
            Int(parameters["digits"] ?? "").flatMap { (6...8).contains($0) ? $0 : nil } ?? 6,
            Int(parameters["period"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 30
        )
    }

    private static func decodeBase32(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "=" }
        var buffer = 0
        var bitsLeft = 0
        var output = Data()
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bitsLeft += 5
            if bitsLeft >= 8 {
                output.append(UInt8((buffer >> (bitsLeft - 8)) & 0xff))
                bitsLeft -= 8
            }
        }
        return output
    }
}
