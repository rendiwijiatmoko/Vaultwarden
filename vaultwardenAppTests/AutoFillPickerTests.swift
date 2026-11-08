import AuthenticationServices
import Foundation
import Testing
@testable import vaultwardenApp

private func login(
    _ id: String,
    name: String,
    uri: String?,
    match: AutoFillURIMatchType? = nil,
    username: String = "",
    totpSecret: String? = nil
) -> AutoFillCredentialRecord {
    AutoFillCredentialRecord(
        id: id,
        name: name,
        username: username,
        password: "secret",
        serviceIdentifier: uri.flatMap(AutoFillSearch.displayHost),
        totpSecret: totpSecret,
        uriRules: uri.map { [AutoFillURIRule(uri: $0, match: match)] }
    )
}

/// A throwaway defaults suite, so tests never touch the App Group.
private struct TemporaryDefaults {
    let suiteName = "AutoFillPickerTests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    func remove() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}

struct AutoFillPickerPartitionTests {
    private func sections(
        _ records: [AutoFillCredentialRecord],
        requesting identifiers: [String],
        defaultMatchType: AutoFillURIMatchType = .baseDomain,
        usage: AutoFillUsageSnapshot = .empty
    ) -> AutoFillPickerSections {
        AutoFillPicker.sections(
            records: records,
            context: .services(identifiers, defaultMatchType: defaultMatchType),
            usage: usage
        )
    }

    @Test func exactHostIsSuggestedAndOtherSitesAreNot() {
        let result = sections(
            [login("a", name: "Example", uri: "https://example.com"), login("b", name: "Other", uri: "other.com")],
            requesting: ["https://example.com/login"]
        )

        #expect(result.suggested.map(\.id) == ["a"])
        #expect(result.other.map(\.id) == ["b"])
        #expect(result.isContextual)
    }

    @Test func subdomainMatchesByBaseDomainButNotByHostRule() {
        let result = sections(
            [
                login("base", name: "Base", uri: "https://example.com"),
                login("host", name: "Host", uri: "https://example.com", match: .host)
            ],
            requesting: ["https://login.example.com"]
        )

        #expect(result.suggested.map(\.id) == ["base"])
        #expect(result.other.map(\.id) == ["host"])
    }

    @Test func baseDomainRespectsTwoLabelPublicSuffixes() {
        let result = sections(
            [login("shop", name: "Shop", uri: "example.co.uk"), login("neighbor", name: "Neighbor", uri: "other.co.uk")],
            requesting: ["https://shop.example.co.uk"]
        )

        #expect(result.suggested.map(\.id) == ["shop"])
        #expect(result.other.map(\.id) == ["neighbor"])
    }

    @Test func neverMatchRuleStaysInOtherEvenOnTheSameHost() {
        let result = sections(
            [login("never", name: "Never", uri: "https://example.com", match: .never)],
            requesting: ["https://example.com"]
        )

        #expect(result.suggested.isEmpty)
        #expect(result.other.map(\.id) == ["never"])
    }

    @Test func defaultNeverMatchTypeAppliesToRulesWithoutTheirOwn() {
        let result = sections(
            [
                login("default", name: "Default", uri: "https://example.com"),
                login("exact", name: "Exact", uri: "https://example.com", match: .exact)
            ],
            requesting: ["https://example.com"],
            defaultMatchType: .never
        )

        #expect(result.suggested.map(\.id) == ["exact"])
        #expect(result.other.map(\.id) == ["default"])
    }

    @Test func noRequestPutsEverythingInOneAlphabeticalSection() {
        let records = [
            login("c10", name: "Site 10", uri: nil),
            login("b", name: "beta", uri: nil),
            login("c9", name: "Site 9", uri: nil),
            login("a", name: "Alpha", uri: nil)
        ]

        for context in [AutoFillPickerContext.none, .services(["  "], defaultMatchType: .baseDomain)] {
            let result = AutoFillPicker.sections(records: records, context: context, usage: .empty)
            #expect(result.suggested.isEmpty)
            #expect(result.other.map(\.id) == ["a", "b", "c9", "c10"])
            #expect(result.isContextual == false)
        }
    }

    @Test func allSuggestedKeepsEveryRecordWithoutHeaders() {
        let result = AutoFillPicker.sections(
            records: [login("b", name: "Bravo", uri: "rp.example"), login("a", name: "Alpha", uri: "rp.example")],
            context: .allSuggested,
            usage: .empty
        )

        #expect(result.suggested.map(\.id) == ["a", "b"])
        #expect(result.other.isEmpty)
        #expect(result.isContextual == false)
    }

    @Test func recentlyUsedLeadsSuggestedThenMatchStrengthThenName() {
        let records = [
            login("old", name: "Alpha", uri: "https://example.com"),
            login("recent", name: "Zulu", uri: "https://example.com"),
            login("exact", name: "Mike", uri: "https://example.com/login", match: .exact),
            login("unused", name: "Bravo", uri: "https://example.com")
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = AutoFillUsageSnapshot(
            accountReference: "account",
            lastUsedByKey: [
                AutoFillUsageHistory.key(accountReference: "account", id: "old"): now.addingTimeInterval(-3_600),
                AutoFillUsageHistory.key(accountReference: "account", id: "recent"): now
            ]
        )

        let result = sections(records, requesting: ["https://example.com/login"], usage: usage)

        #expect(result.suggested.map(\.id) == ["recent", "old", "exact", "unused"])
    }

    @Test func usageFromAnotherAccountDoesNotReorder() {
        let records = [login("b", name: "Bravo", uri: "example.com"), login("a", name: "Alpha", uri: "example.com")]
        let usage = AutoFillUsageSnapshot(
            accountReference: "account",
            lastUsedByKey: [AutoFillUsageHistory.key(accountReference: "someone-else", id: "b"): Date()]
        )

        let result = sections(records, requesting: ["example.com"], usage: usage)

        #expect(result.suggested.map(\.id) == ["a", "b"])
    }
}

struct AutoFillPickerSearchTests {
    @Test(arguments: [
        ("https://www.Example.com/login?next=1", "example.com"),
        ("EXAMPLE.com", "example.com"),
        ("www.example.com:8443/path", "example.com"),
        ("login.example.com", "login.example.com")
    ])
    func displayHostDropsSchemePathPortAndWWW(input: String, expected: String) {
        #expect(AutoFillSearch.displayHost(input) == expected)
    }

    @Test func displayHostRejectsBlankInput() {
        #expect(AutoFillSearch.displayHost("   ") == nil)
    }

    @Test(arguments: ["CAFÉ", "cafe", "Café", "  café  ", "ｃａｆｅ"])
    func foldingIgnoresCaseDiacriticsAndWidth(query: String) {
        let entry = AutoFillPickerEntry(record: login("a", name: "Café Bar", uri: nil))

        #expect(entry.searchKey.contains(AutoFillSearch.normalizedQuery(query)))
    }

    @Test(arguments: ["https://www.example.com/account", "www.example", "EXAMPLE.COM", "jörg", "JORG"])
    func searchMatchesUsernamesAndWebsites(query: String) {
        let sections = AutoFillPickerSections(
            suggested: [],
            other: [AutoFillPickerEntry(record: login("a", name: "Work", uri: "https://example.com", username: "jorg@work.test"))],
            isContextual: false
        )

        #expect(sections.filtered(by: query).other.map(\.id) == ["a"])
    }

    @Test func searchKeepsSectionOrderAndDropsMisses() {
        let sections = AutoFillPicker.sections(
            records: [
                login("b", name: "Bank Two", uri: "bank.example"),
                login("a", name: "Bank One", uri: "bank.example"),
                login("x", name: "Mail", uri: "mail.test"),
                login("c", name: "Bank Three", uri: "elsewhere.test")
            ],
            context: .services(["bank.example"], defaultMatchType: .baseDomain),
            usage: .empty
        )

        let filtered = sections.filtered(by: "bank")

        #expect(filtered.suggested.map(\.id) == ["a", "b"])
        #expect(filtered.other.map(\.id) == ["c"])
        #expect(filtered.orderedIDs == ["a", "b", "c"])
        #expect(sections.filtered(by: "   ") == sections)
    }

    @Test func websitesAreDistinctAndInSavedOrder() {
        let record = AutoFillCredentialRecord(
            id: "a", name: "Multi", username: "", password: "secret",
            serviceIdentifier: "example.com", totpSecret: nil,
            uriRules: [
                AutoFillURIRule(uri: "https://www.example.com/login", match: nil),
                AutoFillURIRule(uri: "https://accounts.example.org", match: .host),
                AutoFillURIRule(uri: "example.com", match: nil)
            ]
        )

        #expect(AutoFillSearch.websites(for: record) == ["example.com", "accounts.example.org"])
    }
}

struct AutoFillLetterTileTests {
    @Test func colorIsStableAcrossLaunchesForKnownHosts() {
        // FNV-1a is fixed, so these must never change between releases.
        #expect(AutoFillLetterTile.paletteIndex(host: "example.com", name: "", paletteCount: 8) == 6)
        #expect(AutoFillLetterTile.paletteIndex(host: "github.com", name: "", paletteCount: 8) == 1)
        #expect(AutoFillLetterTile.paletteIndex(host: "apple.com", name: "", paletteCount: 8) == 0)
    }

    @Test(arguments: ["https://www.example.com/login", "EXAMPLE.com", "example.com"])
    func equivalentHostsShareAColor(host: String) {
        #expect(AutoFillLetterTile.paletteIndex(host: host, name: "Anything", paletteCount: 8) == 6)
    }

    @Test func nameIsTheSeedWhenThereIsNoWebsite() {
        let fromName = AutoFillLetterTile.paletteIndex(host: nil, name: "Amazon", paletteCount: 8)

        #expect(fromName == AutoFillLetterTile.paletteIndex(host: nil, name: "  AMAZON ", paletteCount: 8))
        #expect(fromName == 5)
    }

    @Test func differentHostsSpreadAcrossThePalette() {
        let hosts = (0..<40).map { "site\($0).test" }
        let indices = Set(hosts.map { AutoFillLetterTile.paletteIndex(host: $0, name: "", paletteCount: 8) })

        #expect(indices.count > 4)
        #expect(indices.allSatisfy { (0..<8).contains($0) })
    }

    @Test(arguments: [
        ("  amazon", nil, "A"),
        ("éclair", nil, "É"),
        ("(1) Work", nil, "1"),
        ("", "github.com", "G"),
        ("   ", nil, "?")
    ] as [(String, String?, String)])
    func initialIsTheFirstLetterOrDigit(name: String, host: String?, expected: String) {
        #expect(AutoFillLetterTile.initial(for: name, host: host) == expected)
    }
}

struct AutoFillUsageHistoryTests {
    @Test func recordedUseRoundTripsPerAccount() {
        let storage = TemporaryDefaults()
        defer { storage.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        AutoFillUsageHistory(accountReference: "one", defaults: storage.defaults).recordUse(id: "record", at: date)

        let mine = AutoFillUsageHistory(accountReference: "one", defaults: storage.defaults).snapshot()
        let theirs = AutoFillUsageHistory(accountReference: "two", defaults: storage.defaults).snapshot()
        #expect(mine.lastUsed(id: "record") == date)
        #expect(theirs.lastUsed(id: "record") == nil)
    }

    @Test func storedKeysAreHashesNotRecordIdentifiers() throws {
        let storage = TemporaryDefaults()
        defer { storage.remove() }

        AutoFillUsageHistory(accountReference: "account", defaults: storage.defaults).recordUse(id: "visible-id")

        let stored = try #require(storage.defaults.dictionary(forKey: AutoFillUsageHistory.storageKey))
        #expect(stored.keys.allSatisfy { $0.count == 32 && !$0.contains("visible-id") })
    }

    @Test func capacityKeepsTheMostRecentUses() {
        let storage = TemporaryDefaults()
        defer { storage.remove() }
        let history = AutoFillUsageHistory(accountReference: "account", defaults: storage.defaults, capacity: 2)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        history.recordUse(id: "first", at: start)
        history.recordUse(id: "second", at: start.addingTimeInterval(60))
        history.recordUse(id: "third", at: start.addingTimeInterval(120))

        let snapshot = history.snapshot()
        #expect(snapshot.lastUsedByKey.count == 2)
        #expect(snapshot.lastUsed(id: "first") == nil)
        #expect(snapshot.lastUsed(id: "third") == start.addingTimeInterval(120))
    }

    @Test func rankPutsTheMostRecentFirstAndUnusedAtTheBase() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = AutoFillUsageSnapshot(
            accountReference: "account",
            lastUsedByKey: [
                AutoFillUsageHistory.key(accountReference: "account", id: "older"): start,
                AutoFillUsageHistory.key(accountReference: "account", id: "newer"): start.addingTimeInterval(10)
            ]
        )

        #expect(usage.rank(id: "newer") > usage.rank(id: "older"))
        #expect(usage.rank(id: "older") > usage.rank(id: "unused"))
        #expect(usage.rank(id: "unused") == AutoFillUsageSnapshot.baseRank)
    }
}

struct AutoFillCredentialIdentityRankTests {
    @Test func publishedIdentitiesCarryRecencyRank() throws {
        let passkeyID = Data([1, 2, 3, 4])
        let payload = AutoFillVaultPayload(
            schemaVersion: 4,
            accountReference: "account",
            generatedAt: Date(),
            credentials: [
                login("used", name: "Used", uri: "example.com", username: "a", totpSecret: "JBSWY3DPEHPK3PXP"),
                login("unused", name: "Unused", uri: "example.com", username: "b")
            ],
            passkeys: [
                AutoFillPasskeyRecord(
                    cipherID: "cipher", relyingPartyIdentifier: "example.com", userName: "a",
                    credentialID: passkeyID, userHandle: Data([9]), hasCounter: false
                )
            ],
            passkeyCiphers: nil, cryptoContext: nil, writeSession: nil, userKey: nil,
            folders: nil, passkeyTargets: nil
        )
        let usage = AutoFillUsageSnapshot(
            accountReference: "account",
            lastUsedByKey: [
                AutoFillUsageHistory.key(accountReference: "account", id: "used"): Date(timeIntervalSince1970: 100),
                AutoFillUsageHistory.key(
                    accountReference: "account",
                    id: passkeyID.base64EncodedString()
                ): Date(timeIntervalSince1970: 200)
            ]
        )

        let identities = AutoFillCredentialIdentityBuilder.identities(for: payload, usage: usage)

        let passwords = identities.compactMap { $0 as? ASPasswordCredentialIdentity }
        let used = try #require(passwords.first { $0.recordIdentifier == "password|used" })
        let unused = try #require(passwords.first { $0.recordIdentifier == "password|unused" })
        let code = try #require(identities.compactMap { $0 as? ASOneTimeCodeCredentialIdentity }.first)
        let passkey = try #require(identities.compactMap { $0 as? ASPasskeyCredentialIdentity }.first)
        #expect(used.rank > unused.rank)
        #expect(code.recordIdentifier == "totp|used")
        #expect(code.rank == used.rank)
        #expect(passkey.rank > used.rank)
    }
}

struct AutoFillTOTPTimingTests {
    @Test func secondsRemainingCountsDownWithinThePeriod() {
        let secret = "JBSWY3DPEHPK3PXP"

        #expect(AutoFillTOTP.secondsRemaining(secret: secret, date: Date(timeIntervalSince1970: 1_000_000_000)) == 20)
        #expect(AutoFillTOTP.secondsRemaining(secret: secret, date: Date(timeIntervalSince1970: 1_000_000_019.9)) == 1)
        #expect(AutoFillTOTP.secondsRemaining(secret: secret, date: Date(timeIntervalSince1970: 1_000_000_020)) == 30)
    }

    @Test func periodComesFromTheOtpauthURI() {
        let secret = "otpauth://totp/Example:me?secret=JBSWY3DPEHPK3PXP&period=60"

        #expect(AutoFillTOTP.period(secret: secret) == 60)
        #expect(AutoFillTOTP.secondsRemaining(secret: secret, date: Date(timeIntervalSince1970: 1_000_000_000)) == 20)
    }

    @Test(arguments: [("123456", "123 456"), ("12345678", "1234 5678"), ("1234567", "123 4567"), ("1234", "1234")])
    func codesAreGroupedForReading(code: String, expected: String) {
        #expect(AutoFillTOTP.grouped(code) == expected)
    }
}
