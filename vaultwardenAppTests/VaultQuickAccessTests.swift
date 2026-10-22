import XCTest
@testable import vaultwardenApp

final class VaultQuickAccessTests: XCTestCase {
    func testFavoritesComeFirstWithoutDuplicatesOrTruncatingOtherItems() {
        var favorite = VaultItem(name: "Zulu favorite")
        favorite.isFavorite = true
        var deleted = VaultItem(name: "Deleted favorite")
        deleted.isFavorite = true
        deleted.deletedAt = .now
        var archived = VaultItem(name: "Archived favorite")
        archived.isFavorite = true
        archived.archivedAt = .now
        let others = (0..<40).map { VaultItem(name: "Login \($0)") }
        let sections = VaultQuickAccessSections(items: others + [favorite, deleted, archived], sortOrder: .nameAscending)
        XCTAssertEqual(sections.favorites.map(\.id), [favorite.id])
        XCTAssertEqual(sections.otherItems.count, 40)
        XCTAssertFalse(sections.otherItems.contains { $0.id == favorite.id })
        XCTAssertEqual(sections.otherItems.first?.name, "Login 0")
        XCTAssertEqual(sections.otherItems.last?.name, "Login 39")
    }

    func testTOTPIsResolvedAtCopyTimeAndDoesNotReturnSetupSecret() throws {
        let item = VaultItem(name: "Login", username: "user", password: "secret", totpSecret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        func code(at seconds: TimeInterval) throws -> VaultQuickCopyField {
            try XCTUnwrap(VaultQuickCopyField.fields(for: item, date: Date(timeIntervalSince1970: seconds)).first { $0.id == "totp" })
        }
        XCTAssertEqual(try code(at: 59).value, "287082")
        XCTAssertEqual(try code(at: 60).value, "359152")
        XCTAssertTrue(try code(at: 60).isSensitive)
        XCTAssertFalse(VaultQuickCopyField.fields(for: item).contains { $0.value == item.totpSecret })
    }

    func testCustomFieldsResolveLinkedValuesAndKeepStableIDs() throws {
        let linked = VaultCustomField(name: "Linked password", value: "password", type: .linked)
        let hidden = VaultCustomField(name: "API token", value: "synthetic-token", type: .hidden)
        let boolean = VaultCustomField(name: "Enabled", value: "false", type: .boolean)
        var item = VaultItem(name: "Login", username: "user", password: "secret")
        item.customFields = [linked, hidden, boolean, VaultCustomField(name: "Empty")]
        let original = VaultQuickCopyField.fields(for: item)
        XCTAssertEqual(original.first { $0.title == linked.name }?.value, "secret")
        XCTAssertEqual(original.first { $0.title == linked.name }?.isSensitive, true)
        XCTAssertEqual(original.first { $0.title == hidden.name }?.isSensitive, true)
        XCTAssertEqual(original.first { $0.title == boolean.name }?.value, "false")
        XCTAssertFalse(original.contains { $0.title == "Empty" })
        item.customFields.reverse()
        XCTAssertEqual(original.first { $0.title == hidden.name }?.id,
                       VaultQuickCopyField.fields(for: item).first { $0.title == hidden.name }?.id)
    }

    func testOtherItemTypesExposeAvailableFieldsWithSecretMaskingMetadata() {
        var card = VaultItem(name: "Card", type: .card)
        card.card = CardDetails(cardholderName: "Synthetic User", number: "4111111111111111", expirationMonth: "12", expirationYear: "2030", securityCode: "123")
        let cardFields = VaultQuickCopyField.fields(for: card)
        XCTAssertEqual(cardFields.first { $0.id == "number" }?.isSensitive, true)
        XCTAssertEqual(cardFields.first { $0.id == "security-code" }?.value, "123")
        XCTAssertEqual(cardFields.first { $0.id == "expiry-year" }?.value, "2030")
        var identity = VaultItem(name: "Identity", type: .identity)
        identity.identity = IdentityDetails(firstName: "Synthetic", lastName: "User", email: "test@example.invalid", passportNumber: "synthetic-passport")
        let identityFields = VaultQuickCopyField.fields(for: identity)
        XCTAssertEqual(identityFields.first { $0.id == "email" }?.value, "test@example.invalid")
        XCTAssertEqual(identityFields.first { $0.id == "passport" }?.isSensitive, true)
        let ssh = VaultItem(name: "SSH", username: "synthetic-public", password: "synthetic-private", type: .sshKey)
        XCTAssertEqual(VaultQuickCopyField.fields(for: ssh).first { $0.id == "private-key" }?.isSensitive, true)
        let note = VaultItem(name: "Note", type: .secureNote, notes: "synthetic-note")
        XCTAssertEqual(VaultQuickCopyField.fields(for: note).first { $0.id == "notes" }?.value, "synthetic-note")
    }
}
