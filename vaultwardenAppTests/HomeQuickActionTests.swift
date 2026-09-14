import UIKit
import XCTest
@testable import vaultwardenApp

@MainActor
final class HomeQuickActionTests: XCTestCase {
    func testRouterRecognizesEverySupportedQuickAction() {
        let router = HomeQuickActionRouter.shared
        let actions: [HomeQuickAction] = [.newPassword, .search, .verificationCodes]

        for action in actions {
            let item = UIApplicationShortcutItem(
                type: action.rawValue,
                localizedTitle: action.rawValue
            )

            XCTAssertTrue(router.enqueue(item))
            XCTAssertEqual(router.pendingAction, action)
            router.consume(action)
            XCTAssertNil(router.pendingAction)
        }
    }

    func testRouterRejectsUnknownQuickAction() {
        let item = UIApplicationShortcutItem(
            type: "xyz.0xmwehehe.vaultwardenApp.quickAction.unknown",
            localizedTitle: "Unknown"
        )

        XCTAssertFalse(HomeQuickActionRouter.shared.enqueue(item))
    }
}
