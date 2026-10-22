#if os(macOS)
import AppKit
import XCTest
@testable import vaultwardenApp

@MainActor
final class MacDockVisibilityTests: XCTestCase {
    func testClosingLastTrackedWindowHidesDockAndReopeningRestoresIt() {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let visibility = MacDockVisibility(notifications: notifications, applyPolicy: { policies.append($0) })
        let vault = TestWindow()
        visibility.track(vault)
        XCTAssertEqual(policies.last, .regular)
        // willClose arrives before AppKit clears isVisible.
        notifications.post(name: NSWindow.willCloseNotification, object: vault)
        XCTAssertEqual(policies.last, .accessory)
        visibility.prepareToOpenWindow()
        XCTAssertEqual(policies.last, .regular)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: vault)
        notifications.post(name: NSWindow.willCloseNotification, object: vault)
        XCTAssertEqual(policies.last, .accessory)
    }

    func testSettingsKeepsDockVisibleAndPopoverDoesNotRestoreIt() {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let visibility = MacDockVisibility(notifications: notifications, applyPolicy: { policies.append($0) })
        let vault = TestWindow()
        let settings = TestWindow()
        let popover = TestWindow()
        visibility.track(vault)
        visibility.track(settings)
        notifications.post(name: NSWindow.willCloseNotification, object: vault)
        XCTAssertEqual(policies.last, .regular)
        notifications.post(name: NSWindow.willCloseNotification, object: settings)
        XCTAssertEqual(policies.last, .accessory)
        let count = policies.count
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: popover)
        notifications.post(name: NSWindow.willCloseNotification, object: popover)
        XCTAssertEqual(policies.count, count, "Menu bar and authentication windows must not change Dock visibility")
    }

    func testDisablingMenuBarRestoresDockAccessWithoutAnOpenWindow() {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        let visibility = MacDockVisibility(notifications: notifications, applyPolicy: { policies.append($0) })
        let vault = TestWindow()
        visibility.track(vault)
        notifications.post(name: NSWindow.willCloseNotification, object: vault)
        XCTAssertEqual(policies.last, .accessory)
        visibility.setMenuBarEnabled(false)
        XCTAssertEqual(policies.last, .regular)
        visibility.setMenuBarEnabled(true)
        XCTAssertEqual(policies.last, .accessory)
    }
}

/// No windows are ordered onscreen and no real activation policy is changed.
@MainActor
private final class TestWindow: NSWindow {
    override var isVisible: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}
#endif
