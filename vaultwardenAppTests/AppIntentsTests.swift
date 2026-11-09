import Testing
@testable import vaultwardenApp

@MainActor
@Suite("App Intents")
struct AppIntentsTests {
    @Test("Search text is trimmed before it reaches the search field", arguments: [
        (Optional("  github \n"), "github"),
        (Optional(""), ""),
        (nil, "")
    ])
    func searchRouting(query: String?, expected: String) {
        #expect(SearchVaultIntent.action(for: query) == .search(query: expected))
    }

    @Test func openingQueuesTheActionAndShowsTheVault() {
        let router = HomeQuickActionRouter()
        var showCount = 0
        let previous = AppIntentEnvironment.showVault
        defer { AppIntentEnvironment.showVault = previous }
        AppIntentEnvironment.showVault = { showCount += 1 }

        AppIntentEnvironment.open(.verificationCodes, router: router)

        #expect(router.pendingAction == .verificationCodes)
        #expect(showCount == 1)
    }

    @Test func openingWithoutAnActionLeavesNothingPending() {
        let router = HomeQuickActionRouter()
        let previous = AppIntentEnvironment.showVault
        defer { AppIntentEnvironment.showVault = previous }
        AppIntentEnvironment.showVault = nil

        AppIntentEnvironment.open(nil, router: router)

        #expect(router.pendingAction == nil)
    }

    @Test func generatedPasswordHonorsLengthAndClasses() {
        let value = GeneratePasswordIntent.generate(
            kind: .password,
            length: 32,
            wordCount: 4,
            includesUppercase: false,
            includesNumbers: true,
            includesSymbols: false
        )

        #expect(value.count == 32)
        #expect(value.allSatisfy { SecretGenerator.lowercase.contains($0) || SecretGenerator.digits.contains($0) })
        #expect(value.contains { SecretGenerator.digits.contains($0) })
    }

    @Test func generatedPassphraseUsesTheRequestedWordCount() {
        let value = GeneratePasswordIntent.generate(
            kind: .passphrase,
            length: 20,
            wordCount: 6,
            includesUppercase: false,
            includesNumbers: false,
            includesSymbols: true
        )

        #expect(value.split(separator: "-").count == 6)
    }

    @Test func intentErrorsHaveDistinctMessages() {
        let messages = [VaultIntentError.signedOut, .locked, .syncFailed].map {
            String(localized: $0.localizedStringResource)
        }
        #expect(Set(messages).count == 3)
    }
}
