import Foundation
import Testing
@testable import vaultwardenApp

struct VaultSearchTests {
    private let items = [
        VaultItem(name: "GitHub", username: "octo@example.com", password: "hunter2-secret", uri: "https://github.com"),
        VaultItem(name: "Café Mail", username: "lu", password: "p", uri: "mail.example.net"),
        VaultItem(name: "Bank", username: "", password: "bankpass", folder: "Finance", notes: "PIN 4321")
    ]

    private func names(matching text: String) -> [String] {
        VaultSearch.filter(items, query: VaultSearchQuery(text)).map(\.name)
    }

    @Test func matchesNameUserNameAndWebsite() {
        #expect(names(matching: "git") == ["GitHub"])
        #expect(names(matching: "octo@") == ["GitHub"])
        #expect(names(matching: "example.net") == ["Café Mail"])
        #expect(names(matching: "finance") == ["Bank"])
    }

    @Test func ignoresCaseAndAccents() {
        #expect(names(matching: "CAFE") == ["Café Mail"])
        #expect(names(matching: "café") == ["Café Mail"])
    }

    @Test func everyTermMustMatch() {
        #expect(names(matching: "github octo") == ["GitHub"])
        #expect(names(matching: "github bank").isEmpty)
    }

    @Test func neverSearchesSecretsOrNotes() {
        #expect(names(matching: "hunter2").isEmpty)
        #expect(names(matching: "bankpass").isEmpty)
        #expect(names(matching: "4321").isEmpty)
    }

    @Test func emptyQueryKeepsEverything() {
        #expect(names(matching: "   ").count == items.count)
    }

    @Test func termsDoNotSpanFields() {
        // "github" ends the name and "octo" starts the user name; joined they'd match.
        #expect(names(matching: "huboct").isEmpty)
    }
}

struct VaultItemPresentationTests {
    @Test func loginSubtitleFallsBackToTheWebsite() {
        #expect(VaultItemPresentation.subtitle(for: VaultItem(name: "A", username: "me")) == "me")
        #expect(VaultItemPresentation.subtitle(for: VaultItem(name: "A", uri: "https://www.github.com/login")) == "github.com")
    }

    @Test func cardSubtitleShowsOnlyTheLastFourDigits() {
        var item = VaultItem(name: "Visa", type: .card)
        item.card = CardDetails(brand: "Visa", number: "4242 4242 4242 4242", securityCode: "123")
        let subtitle = VaultItemPresentation.subtitle(for: item)
        #expect(subtitle == "Visa •••• 4242")
        #expect(subtitle.contains("123") == false)
    }

    @Test func changePasswordURLUsesTheWellKnownPath() throws {
        let item = VaultItem(name: "GitHub", password: "x", uri: "http://user@github.com/login?next=1")
        let url = try #require(VaultItemPresentation.changePasswordURL(for: item))
        #expect(url.absoluteString == "https://github.com/.well-known/change-password")
    }

    @Test func noChangePasswordURLWithoutAWebsite() {
        #expect(VaultItemPresentation.changePasswordURL(for: VaultItem(name: "A", password: "x")) == nil)
        #expect(VaultItemPresentation.changePasswordURL(for: VaultItem(name: "A", uri: "androidapp://com.example")) == nil)
    }
}

struct VaultWebsiteInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com/login  ", "https://example.com/login"),
        ("http://intranet.example", "http://intranet.example"),
        ("androidapp://com.example.app", "androidapp://com.example.app"),
        ("nas", "nas")
    ])
    func normalizes(input: String, expected: String) {
        #expect(VaultWebsiteInput.normalize(input) == .valid(expected))
    }

    @Test func spacesAreInvalid() {
        #expect(VaultWebsiteInput.normalize("my bank.com") == .invalid)
    }

    @Test func blankIsEmpty() {
        #expect(VaultWebsiteInput.normalize("   ") == .empty)
    }

    @Test func suggestsANameFromTheDomain() {
        #expect(VaultWebsiteInput.suggestedName(for: "www.github.com/login") == "github.com")
        #expect(VaultWebsiteInput.suggestedName(for: "") == nil)
    }
}

struct VaultSecurityGroupTests {
    @Test func eachItemAppearsOnceUnderItsMostUrgentIssue() {
        var leaked = VaultItem(name: "Leaked")
        leaked.risks = [.exposed, .reused, .weak]
        var reused = VaultItem(name: "Reused")
        reused.risks = [.reused]
        var plain = VaultItem(name: "Plain")
        plain.risks = []
        var http = VaultItem(name: "HTTP")
        http.risks = [.unsecured]

        let groups = VaultSecurityGroup.grouped([reused, plain, leaked, http])
        #expect(groups.map(\.issue) == [.compromised, .reused, .unsecuredWebsite])
        #expect(groups.map { $0.items.map(\.name) } == [["Leaked"], ["Reused"], ["HTTP"]])
    }

    @Test func issueFollowsPriority() {
        #expect(VaultSecurityIssue(risks: [.weak, .reused]) == .reused)
        #expect(VaultSecurityIssue(risks: []) == nil)
    }
}

struct VaultPasswordStrengthTests {
    @Test(arguments: ["abc", "password", "Password1!", "aaaaaaaaaaaaaaaa", "12345678", "qwertyui"])
    func weakPasswords(password: String) {
        #expect(VaultPasswordStrength.isWeak(password))
    }

    @Test(arguments: ["T7#kq9!Vz2@pLm4x", "correct-horse-battery-staple", "Xk3rTz9qBnW2"])
    func strongPasswords(password: String) {
        #expect(VaultPasswordStrength.isWeak(password) == false)
    }

    @Test func emptyIsNotReportedAsWeak() {
        #expect(VaultPasswordStrength.isWeak("") == false)
    }
}

struct TOTPDisplayTests {
    @Test(arguments: [("123456", "123 456"), ("12345678", "1234 5678"), ("1234567", "123 4567"), ("1234", "1234")])
    func groupsCodes(code: String, expected: String) {
        #expect(TOTPDisplay.grouped(code) == expected)
    }

    @Test func secondsRemainingCountsDownWithinThePeriod() {
        #expect(TOTPDisplay.secondsRemaining(at: Date(timeIntervalSince1970: 60), period: 30) == 30)
        #expect(TOTPDisplay.secondsRemaining(at: Date(timeIntervalSince1970: 61.5), period: 30) == 29)
        #expect(TOTPDisplay.secondsRemaining(at: Date(timeIntervalSince1970: 89), period: 30) == 1)
        #expect(TOTPDisplay.secondsRemaining(at: Date(timeIntervalSince1970: 89), period: 0) == 1)
    }
}
