import XCTest
@testable import vaultwardenApp

@MainActor
final class HomeQuickActionTests: XCTestCase {
    func testRouterRecognizesEverySupportedQuickAction() {
        let router = HomeQuickActionRouter.shared
        let actions: [HomeQuickAction] = [.newPassword, .search, .verificationCodes]

        for action in actions {
            XCTAssertTrue(router.enqueue(rawValue: action.rawValue))
            XCTAssertEqual(router.pendingAction, action)
            router.consume(action)
            XCTAssertNil(router.pendingAction)
        }
    }

    func testRouterRejectsUnknownQuickAction() {
        XCTAssertFalse(HomeQuickActionRouter.shared.enqueue(rawValue: "xyz.0xmwehehe.vaultwardenApp.quickAction.unknown"))
    }
}
