#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true)
    }
}

/// Owns a popover that can also be presented by an incoming SSH request.
@MainActor
final class MacMenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var isEnabled = true
    var openVaultWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    let dockVisibility = MacDockVisibility()
    private let store: AppStore
    private let agent: MacSSHAgent
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    private var openingWindow = false

    init(store: AppStore, agent: MacSSHAgent) {
        self.store = store
        self.agent = agent
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibility() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &subscriptions)
        Publishers.CombineLatest(store.$isLocked, store.$authenticatedSession.map { $0 != nil })
            .sink { [weak self] locked, authenticated in
                self?.updateIcon(locked: locked, authenticated: authenticated)
            }
            .store(in: &subscriptions)
    }

    private func updateVisibility() {
        let enabled = UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
        if isEnabled != enabled { isEnabled = enabled }
        dockVisibility.setMenuBarEnabled(enabled)
        if enabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            updateIcon(locked: store.isLocked, authenticated: store.isAuthenticated)
        } else if !enabled, let item = statusItem {
            agent.resolvePrompt(approved: false)
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateIcon(locked: Bool, authenticated: Bool) {
        let symbol = authenticated && !locked ? "lock.shield" : "lock.shield.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Vaultwarden")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        if let image, image.size.height > 0 {
            // Use the menu bar's available height instead of the small default
            // symbol size, preserving the shield's natural proportions.
            image.size = NSSize(width: image.size.width * 20 / image.size.height, height: 20)
        }
        image?.isTemplate = true
        statusItem?.button?.imageScaling = .scaleProportionallyDown
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Vaultwarden — " + L10n.string(
            !authenticated ? "Signed out" : (locked ? "Vault Locked" : "Vault Unlocked")
        )
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button, button.window != nil else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView:
                MacMenuBarView(store: store, agent: agent, controller: self)
                    .environmentObject(store)
                    .environmentObject(agent)
            )
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func presentSSHRequest() {
        updateVisibility()
        if isEnabled { showPopover() } else { openVaultWindow?() }
    }

    func openVault() {
        openingWindow = true
        defer { openingWindow = false }
        popover.performClose(nil)
        dockVisibility.prepareToOpenWindow()
        openVaultWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        openingWindow = true
        defer { openingWindow = false }
        popover.performClose(nil)
        dockVisibility.prepareToOpenWindow()
        openSettingsWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Keep authorization visible during a system authentication dialog.
        agent.prompt == nil
    }

    func popoverDidClose(_ notification: Notification) {
        // Destroy local search, password and generator state when dismissed.
        popover.contentViewController = nil
        if let prompt = agent.prompt { agent.cancelPrompt(id: prompt.id) }
        if !openingWindow, store.settings.vaultTimeout == .immediately, store.isAuthenticated, !store.isLocked {
            store.lock(requestAutomaticUnlock: false)
        }
    }
}
#endif
