import Foundation

/// Derived from the current item; copy actions retain only the item and field IDs.
nonisolated struct VaultQuickCopyField: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbol: String
    let isSensitive: Bool
    let isCustom: Bool

    static func fields(for item: VaultItem, date: Date = Date()) -> [Self] {
        var fields: [Self] = []
        func add(_ id: String, _ title: String, _ value: String, _ symbol: String,
                 sensitive: Bool = false, custom: Bool = false) {
            guard !value.isEmpty else { return }
            fields.append(Self(id: id, title: title, value: value, symbol: symbol,
                               isSensitive: sensitive, isCustom: custom))
        }
        switch item.type {
        case .login:
            add("username", "Username", item.username, "person.crop.circle")
            add("password", "Password", item.password, "key.fill", sensitive: true)
            if let secret = item.totpSecret, let code = TOTPGenerator.code(secret: secret, date: date) {
                add("totp", "Verification code", code, "lock.rotation", sensitive: true)
            }
            for (index, uri) in item.websiteURIs.enumerated() {
                add("uri-\(index)", "Website URI", uri, "link")
            }
        case .secureNote:
            break
        case .sshKey:
            add("public-key", "Public key", item.username, "key")
            add("private-key", "Private key", item.password, "key.fill", sensitive: true)
            add("fingerprint", "Fingerprint", item.displayedSSHFingerprint, "number")
        case .card:
            if let card = item.card {
                add("cardholder", "Cardholder", card.cardholderName, "person")
                add("brand", "Brand", card.brand, "creditcard")
                add("number", "Number", card.number, "creditcard.fill", sensitive: true)
                add("security-code", "Security code", card.securityCode, "lock.fill", sensitive: true)
                add("expiry-month", "Expiration month", card.expirationMonth, "calendar")
                add("expiry-year", "Expiration year", card.expirationYear, "calendar")
                add("valid-month", "Valid from month", card.validFromMonth, "calendar")
                add("valid-year", "Valid from year", card.validFromYear, "calendar")
            }
        case .identity:
            if let identity = item.identity {
                add("full-name", "Full name", identity.fullName, "person.text.rectangle")
                add("title", "Title", identity.title, "person")
                add("first-name", "First name", identity.firstName, "person")
                add("middle-name", "Middle name", identity.middleName, "person")
                add("last-name", "Last name", identity.lastName, "person")
                add("username", "Username", identity.username, "person.crop.circle")
                add("company", "Company", identity.company, "building.2")
                add("email", "Email", identity.email, "envelope")
                add("phone", "Phone", identity.phone, "phone")
                add("ssn", "Social security number", identity.socialSecurityNumber, "number", sensitive: true)
                add("passport", "Passport number", identity.passportNumber, "person.text.rectangle", sensitive: true)
                add("license", "License number", identity.licenseNumber, "person.text.rectangle", sensitive: true)
                add("address1", "Address line 1", identity.address1, "house")
                add("address2", "Address line 2", identity.address2, "house")
                add("city", "City", identity.city, "mappin")
                add("state", "State / Province", identity.state, "mappin")
                add("postal-code", "Postal code", identity.postalCode, "number")
                add("country", "Country", identity.country, "globe")
            }
        }
        add("notes", "Notes", item.notes, "note.text", sensitive: true)
        for field in item.customFields {
            let linkedPassword = field.type == .linked && field.value == "password"
            let value = field.type == .linked ? (linkedPassword ? item.password : item.username) : field.value
            add("custom-\(field.id)", field.name, value, field.type.icon,
                sensitive: field.type == .hidden || linkedPassword, custom: true)
        }
        return fields
    }
}

nonisolated struct VaultQuickAccessSections {
    let favorites: [VaultItem]
    let otherItems: [VaultItem]

    init(items: [VaultItem], sortOrder: VaultSortOrder) {
        let sorted = items.filter { !$0.isDeleted && !$0.isArchived }
            .sorted(by: sortOrder.areInIncreasingOrder)
        favorites = sorted.filter(\.isFavorite)
        otherItems = sorted.filter { !$0.isFavorite }
    }
}
