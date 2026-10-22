#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Only vault and Settings windows affect Dock visibility. The status-item
/// popover and system authentication windows must remain accessory surfaces.
@MainActor
final class MacDockVisibility {
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var closedWindows: Set<ObjectIdentifier> = []
    private var subscriptions: Set<AnyCancellable> = []
    private var menuBarEnabled = true
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    init(
        notifications: NotificationCenter = .default,
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { policy in
            if NSApplication.shared.activationPolicy() != policy {
                NSApplication.shared.setActivationPolicy(policy)
            }
        }
    ) {
        self.applyPolicy = applyPolicy
        notifications.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow,
                          self.windows.contains(window) else { return }
                    self.closedWindows.insert(ObjectIdentifier(window))
                    self.updatePolicy()
                }
            }
            .store(in: &subscriptions)
        notifications.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow,
                          self.windows.contains(window) else { return }
                    self.closedWindows.remove(ObjectIdentifier(window))
                    self.prepareToOpenWindow()
                }
            }
            .store(in: &subscriptions)
    }

    func track(_ window: NSWindow) {
        windows.add(window)
        closedWindows.remove(ObjectIdentifier(window))
        prepareToOpenWindow()
    }

    func setMenuBarEnabled(_ enabled: Bool) {
        guard menuBarEnabled != enabled else { return }
        menuBarEnabled = enabled
        updatePolicy()
    }

    func prepareToOpenWindow() {
        applyPolicy(.regular)
    }

    private func updatePolicy() {
        let hasWindow = windows.allObjects.contains {
            !closedWindows.contains(ObjectIdentifier($0)) && ($0.isVisible || $0.isMiniaturized)
        }
        applyPolicy(menuBarEnabled && !hasWindow ? .accessory : .regular)
    }
}

/// Obtains the actual SwiftUI scene window without replacing its delegate.
struct MacWindowRegistration: NSViewRepresentable {
    let dockVisibility: MacDockVisibility

    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.onWindow = { [weak dockVisibility] window in dockVisibility?.track(window) }
        return view
    }

    func updateNSView(_ nsView: WindowReader, context: Context) {}

    final class WindowReader: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
#endif
