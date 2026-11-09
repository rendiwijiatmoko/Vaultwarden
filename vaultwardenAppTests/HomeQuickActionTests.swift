import Testing
@testable import vaultwardenApp

@MainActor
@Suite("Home Screen quick actions")
struct HomeQuickActionTests {
    @Test("Every Info.plist shortcut type maps to its action and back", arguments: [
        HomeQuickAction.newPassword,
        .search(query: ""),
        .verificationCodes,
        .generator
    ])
    func roundTrip(action: HomeQuickAction) {
        #expect(HomeQuickAction(shortcutType: action.shortcutType) == action)
    }

    @Test func routerQueuesAndConsumesRecognizedShortcut() {
        let router = HomeQuickActionRouter()

        #expect(router.enqueue(shortcutType: HomeQuickAction.ShortcutType.generator))
        #expect(router.pendingAction == .generator)

        router.consume(.generator)
        #expect(router.pendingAction == nil)
    }

    @Test func routerRejectsUnknownShortcut() {
        let router = HomeQuickActionRouter()

        #expect(!router.enqueue(shortcutType: "xyz.0xmwehehe.vaultwardenApp.quickAction.unknown"))
        #expect(router.pendingAction == nil)
    }

    @Test func consumingADifferentActionKeepsTheNewerOnePending() {
        let router = HomeQuickActionRouter()
        router.enqueue(.search(query: "github"))

        router.consume(.search(query: "gitlab"))
        router.consume(.verificationCodes)

        #expect(router.pendingAction == .search(query: "github"))
    }

    @Test func newestActionReplacesAnOlderPendingOne() {
        let router = HomeQuickActionRouter()
        router.enqueue(.newPassword)
        router.enqueue(.verificationCodes)

        #expect(router.pendingAction == .verificationCodes)
    }
}
