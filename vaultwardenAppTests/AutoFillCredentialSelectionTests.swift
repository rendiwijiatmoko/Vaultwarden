import XCTest
@testable import vaultwardenApp

final class AutoFillCredentialSelectionTests: XCTestCase {
    private func login(
        id: String,
        password: String = "secret",
        totpSecret: String? = nil,
        itemType: AutoFillItemType? = nil
    ) -> AutoFillCredentialRecord {
        AutoFillCredentialRecord(
            id: id, name: "Example", username: "user-\(id)", password: password,
            serviceIdentifier: "example.com", totpSecret: totpSecret, itemType: itemType
        )
    }

    func testSelectedPasswordWinsAmongLoginsForTheSameDomain() {
        let first = login(id: "first")
        let selected = login(id: "selected")
        let selection = AutoFillCredentialSelection.password(recordIdentifier: "password|selected")

        XCTAssertEqual(selection.resolve(in: [first, selected]), selected)
        XCTAssertEqual(selection.resolve(in: [selected, first]), selected)
    }

    func testMissingSelectedLoginDoesNotFallBackToAnotherAccount() {
        let selection = AutoFillCredentialSelection.password(recordIdentifier: "password|deleted")

        XCTAssertNil(selection.resolve(in: [login(id: "other-account")]))
    }

    func testInvalidPasswordIdentitiesNeverResolve() {
        let credentials = [login(id: "selected")]
        let invalid: [String?] = [nil, "", "password|", "|selected", "totp|selected", "password|extra|selected"]

        for identifier in invalid {
            XCTAssertNil(AutoFillCredentialSelection.password(recordIdentifier: identifier)
                .resolve(in: credentials))
        }
    }

    func testUnprefixedPasswordIdentityResolves() {
        let selected = login(id: "selected")

        XCTAssertEqual(AutoFillCredentialSelection.password(recordIdentifier: "selected")
            .resolve(in: [selected]), selected)
    }

    func testPasswordSelectionRequiresALoginWithAPassword() {
        let selection = AutoFillCredentialSelection.password(recordIdentifier: "password|selected")

        XCTAssertNil(selection.resolve(in: [login(id: "selected", password: "")]))
        XCTAssertNil(selection.resolve(in: [login(id: "selected", itemType: .secureNote)]))
    }

    func testOneTimeCodeSelectionResolvesWithoutAPassword() {
        let selected = login(id: "selected", password: "", totpSecret: "JBSWY3DPEHPK3PXP")
        let selection = AutoFillCredentialSelection.oneTimeCode(recordIdentifier: "totp|selected")

        XCTAssertEqual(selection.resolve(in: [login(id: "other"), selected]), selected)
    }

    func testOneTimeCodeSelectionRejectsMissingSecretAndWrongIdentityType() {
        let selection = AutoFillCredentialSelection.oneTimeCode(recordIdentifier: "totp|selected")
        XCTAssertNil(selection.resolve(in: [login(id: "selected")]))
        XCTAssertNil(selection.resolve(in: [login(id: "selected", totpSecret: "")]))

        let selected = login(id: "selected", totpSecret: "JBSWY3DPEHPK3PXP")
        XCTAssertNil(AutoFillCredentialSelection.oneTimeCode(recordIdentifier: "password|selected")
            .resolve(in: [selected]))
    }
}
