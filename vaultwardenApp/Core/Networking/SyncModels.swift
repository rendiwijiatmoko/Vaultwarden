import BitwardenSdk
import Foundation

nonisolated struct SyncResponseDTO: Decodable, Sendable {
    let profile: SyncProfileDTO?
    let folders: [SyncFolderDTO]
    let collections: [SyncCollectionDTO]
    let ciphers: [SyncCipherDTO]
    let sends: [SyncSendDTO]

    private enum CodingKeys: String, CodingKey { case profile, folders, collections, ciphers, sends }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(SyncProfileDTO.self, forKey: .profile)
        folders = try container.decodeIfPresent([SyncFolderDTO].self, forKey: .folders) ?? []
        collections = try container.decodeIfPresent([SyncCollectionDTO].self, forKey: .collections) ?? []
        ciphers = try container.decodeIfPresent([SyncCipherDTO].self, forKey: .ciphers) ?? []
        sends = try container.decodeIfPresent([SyncSendDTO].self, forKey: .sends) ?? []
    }
}

nonisolated struct SyncProfileDTO: Decodable, Sendable {
    let id: String
    let organizations: [SyncOrganizationDTO]

    private enum CodingKeys: String, CodingKey { case id, organizations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        organizations = try container.decodeIfPresent([SyncOrganizationDTO].self, forKey: .organizations) ?? []
    }
}

nonisolated struct SyncOrganizationDTO: Decodable, Sendable {
    let id: String
    let name: String?
    let key: String?
}

nonisolated struct SyncFolderDTO: Decodable, Sendable {
    let id: String
    let name: String
    let revisionDate: String
}

nonisolated struct SyncCollectionDTO: Decodable, Sendable {
    let id: String
    let organizationId: String
    let name: String
    let externalId: String?
    let hidePasswords: Bool
    let readOnly: Bool
    let manage: Bool?
    let defaultUserCollectionEmail: String?
    let type: Int?

    private enum CodingKeys: String, CodingKey {
        case id, organizationId, name, externalId, hidePasswords, readOnly, manage
        case defaultUserCollectionEmail, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        organizationId = try container.decode(String.self, forKey: .organizationId)
        name = try container.decode(String.self, forKey: .name)
        externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
        hidePasswords = try container.decodeIfPresent(Bool.self, forKey: .hidePasswords) ?? false
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        manage = try container.decodeIfPresent(Bool.self, forKey: .manage)
        defaultUserCollectionEmail = try container.decodeIfPresent(String.self, forKey: .defaultUserCollectionEmail)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
    }
}

nonisolated struct SyncSendDTO: Decodable, Sendable {
    let id: String
    let accessId: String?
    let type: Int
    let name: String
    let notes: String?
    let file: SyncSendFileDTO?
    let text: SyncSendTextDTO?
    let key: String
    let maxAccessCount: UInt32?
    let accessCount: UInt32
    let password: String?
    let disabled: Bool
    let revisionDate: String
    let expirationDate: String?
    let deletionDate: String
    let hideEmail: Bool
    let emails: String?
    let authType: Int?
}

nonisolated struct SyncSendFileDTO: Decodable, Sendable {
    let id: String?
    let fileName: String
    let size: String?
    let sizeName: String?
}

nonisolated struct SyncSendTextDTO: Decodable, Sendable {
    let text: String?
    let hidden: Bool
}

nonisolated struct SyncCipherDTO: Decodable, Sendable {
    let id: String
    let organizationId: String?
    let folderId: String?
    let collectionIds: [String]
    let key: String?
    let name: String?
    let notes: String?
    let type: Int
    let login: SyncLoginDTO?
    let identity: SyncIdentityDTO?
    let card: SyncCardDTO?
    let secureNote: SyncSecureNoteDTO?
    let sshKey: SyncSSHKeyDTO?
    let favorite: Bool
    let reprompt: Int
    let organizationUseTotp: Bool
    let edit: Bool
    let viewPassword: Bool
    let fields: [SyncFieldDTO]?
    let attachments: [SyncAttachmentDTO]?
    let creationDate: String
    let deletedDate: String?
    let revisionDate: String
    let archivedDate: String?
    let data: String?

    private enum CodingKeys: String, CodingKey {
        case id, organizationId, folderId, collectionIds, key, name, notes, type, login, identity, card
        case secureNote, sshKey, favorite, reprompt, organizationUseTotp, edit, viewPassword, fields
        case creationDate, deletedDate, revisionDate, archivedDate, data, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyData = try? container.decode(SyncCipherLegacyDataDTO.self, forKey: .data)
        id = try container.decode(String.self, forKey: .id)
        organizationId = try container.decodeIfPresent(String.self, forKey: .organizationId)
        folderId = try container.decodeIfPresent(String.self, forKey: .folderId)
        collectionIds = try container.decodeIfPresent([String].self, forKey: .collectionIds) ?? []
        key = try container.decodeIfPresent(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? legacyData?.name
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? legacyData?.notes
        type = try container.decode(Int.self, forKey: .type)
        login = try container.decodeIfPresent(SyncLoginDTO.self, forKey: .login)
            ?? (type == 1 ? legacyData?.resolvedLogin : nil)
        identity = try container.decodeIfPresent(SyncIdentityDTO.self, forKey: .identity)
            ?? (type == 4 ? legacyData?.resolvedIdentity : nil)
        card = try container.decodeIfPresent(SyncCardDTO.self, forKey: .card)
            ?? (type == 3 ? legacyData?.resolvedCard : nil)
        secureNote = try container.decodeIfPresent(SyncSecureNoteDTO.self, forKey: .secureNote)
            ?? (type == 2 ? SyncSecureNoteDTO(type: 0) : nil)
        sshKey = try container.decodeIfPresent(SyncSSHKeyDTO.self, forKey: .sshKey)
            ?? (type == 5 ? legacyData?.resolvedSSHKey : nil)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        reprompt = try container.decodeIfPresent(Int.self, forKey: .reprompt) ?? 0
        organizationUseTotp = try container.decodeIfPresent(Bool.self, forKey: .organizationUseTotp) ?? false
        edit = try container.decodeIfPresent(Bool.self, forKey: .edit) ?? true
        viewPassword = try container.decodeIfPresent(Bool.self, forKey: .viewPassword) ?? true
        fields = try container.decodeIfPresent([SyncFieldDTO].self, forKey: .fields) ?? legacyData?.fields
        attachments = try container.decodeIfPresent([SyncAttachmentDTO].self, forKey: .attachments)
        creationDate = try container.decode(String.self, forKey: .creationDate)
        deletedDate = try container.decodeIfPresent(String.self, forKey: .deletedDate)
        revisionDate = try container.decode(String.self, forKey: .revisionDate)
        archivedDate = try container.decodeIfPresent(String.self, forKey: .archivedDate)
        // New Bitwarden servers may return an encrypted blob String here. Vaultwarden also
        // returns the legacy field-level payload as an object on some compatibility versions.
        // Only the String form is passed to the SDK as blob-encrypted data; object fields are
        // merged into the legacy properties above.
        data = try? container.decode(String.self, forKey: .data)
    }
}

nonisolated struct SyncAttachmentDTO: Decodable, Sendable {
    let id: String?
    let url: String?
    let size: String?
    let sizeName: String?
    let fileName: String?
    let key: String?

    var sdkAttachment: Attachment {
        Attachment(id: id, url: url, size: size, sizeName: sizeName, fileName: fileName, key: key)
    }
}

/// Compatibility shape used by Vaultwarden when `cipher.data` is a JSON object instead of
/// Bitwarden's newer encrypted blob String. Login/card/identity/SSH fields may be flattened.
nonisolated struct SyncCipherLegacyDataDTO: Decodable, Sendable {
    let name: String?
    let notes: String?
    let fields: [SyncFieldDTO]?
    let login: SyncLoginDTO?
    let identity: SyncIdentityDTO?
    let card: SyncCardDTO?
    let sshKey: SyncSSHKeyDTO?

    let username: String?
    let password: String?
    let passwordRevisionDate: String?
    let uris: [SyncLoginURIDTO]?
    let uri: String?
    let totp: String?
    let autofillOnPageLoad: Bool?
    let fido2Credentials: [SyncFido2CredentialDTO]?

    let cardholderName: String?
    let expMonth: String?
    let expYear: String?
    let code: String?
    let brand: String?
    let number: String?

    let title: String?
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let address1: String?
    let address2: String?
    let address3: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let company: String?
    let email: String?
    let phone: String?
    let ssn: String?
    let identityUsername: String?
    let passportNumber: String?
    let licenseNumber: String?

    let privateKey: String?
    let publicKey: String?
    let keyFingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case name, notes, fields, login, identity, card, sshKey
        case username, password, passwordRevisionDate, uris, uri, totp, autofillOnPageLoad, fido2Credentials
        case cardholderName, expMonth, expYear, code, brand, number
        case title, firstName, middleName, lastName, address1, address2, address3, city, state
        case postalCode, country, company, email, phone, ssn, identityUsername, passportNumber, licenseNumber
        case privateKey, publicKey, keyFingerprint
    }

    var resolvedLogin: SyncLoginDTO? {
        if let login { return login }
        guard username != nil || password != nil || totp != nil || uris != nil || uri != nil else { return nil }
        let resolvedURIs = uris ?? uri.map { [SyncLoginURIDTO(uri: $0, match: nil, uriChecksum: nil)] }
        return SyncLoginDTO(
            username: username,
            password: password,
            passwordRevisionDate: passwordRevisionDate,
            uris: resolvedURIs,
            totp: totp,
            autofillOnPageLoad: autofillOnPageLoad,
            fido2Credentials: fido2Credentials
        )
    }

    var resolvedCard: SyncCardDTO? {
        if let card { return card }
        guard cardholderName != nil || number != nil || code != nil else { return nil }
        return SyncCardDTO(
            cardholderName: cardholderName,
            expMonth: expMonth,
            expYear: expYear,
            code: code,
            brand: brand,
            number: number
        )
    }

    var resolvedIdentity: SyncIdentityDTO? {
        if let identity { return identity }
        guard firstName != nil || lastName != nil || email != nil || identityUsername != nil else { return nil }
        return SyncIdentityDTO(
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
            username: identityUsername ?? username,
            passportNumber: passportNumber,
            licenseNumber: licenseNumber
        )
    }

    var resolvedSSHKey: SyncSSHKeyDTO? {
        if let sshKey { return sshKey }
        guard let privateKey else { return nil }
        return SyncSSHKeyDTO(privateKey: privateKey, publicKey: publicKey, keyFingerprint: keyFingerprint)
    }
}

nonisolated struct SyncLoginDTO: Decodable, Sendable {
    let username: String?
    let password: String?
    let passwordRevisionDate: String?
    let uris: [SyncLoginURIDTO]?
    let totp: String?
    let autofillOnPageLoad: Bool?
    let fido2Credentials: [SyncFido2CredentialDTO]?
}

nonisolated struct SyncLoginURIDTO: Decodable, Sendable {
    let uri: String?
    let match: Int?
    let uriChecksum: String?
}

nonisolated struct SyncFido2CredentialDTO: Decodable, Sendable {
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
    let creationDate: String
}

nonisolated struct SyncCardDTO: Decodable, Sendable {
    let cardholderName: String?
    let expMonth: String?
    let expYear: String?
    let code: String?
    let brand: String?
    let number: String?
}

nonisolated struct SyncIdentityDTO: Decodable, Sendable {
    let title: String?
    let firstName: String?
    let middleName: String?
    let lastName: String?
    let address1: String?
    let address2: String?
    let address3: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let company: String?
    let email: String?
    let phone: String?
    let ssn: String?
    let username: String?
    let passportNumber: String?
    let licenseNumber: String?
}

nonisolated struct SyncSecureNoteDTO: Decodable, Sendable {
    let type: Int
}

nonisolated struct SyncSSHKeyDTO: Decodable, Sendable {
    let privateKey: String
    let publicKey: String?
    let keyFingerprint: String?
}

nonisolated struct SyncFieldDTO: Decodable, Sendable {
    let name: String?
    let value: String?
    let type: Int
    let linkedId: UInt32?
}

nonisolated enum ServerDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
