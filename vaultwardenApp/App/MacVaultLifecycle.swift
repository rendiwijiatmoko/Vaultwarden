#if os(macOS)
import AppKit
import Combine
import CoreGraphics

/// One application-wide observer, shared by every vault and Settings window.
/// Scene inactivity alone is insufficient on Mac: another app window can be active.
@MainActor
final class MacVaultLifecycle {
    private static var current: MacVaultLifecycle?

    static func start(store: AppStore) {
        guard current?.store !== store else { return }
        current = MacVaultLifecycle(store: store)
    }

    private let store: AppStore
    private let applicationIsActive: @MainActor () -> Bool
    private var subscriptions: Set<AnyCancellable> = []
    private let idleSeconds: @MainActor () -> TimeInterval
    private let now: @MainActor () -> Date
    private var unlockedAt: Date?
    private var timeout: VaultTimeout

    init(
        store: AppStore,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
        applicationNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenLockNotifications: NotificationCenter = DistributedNotificationCenter.default(),
        idleSeconds: @escaping @MainActor () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.applicationIsActive = applicationIsActive
        self.idleSeconds = idleSeconds
        self.now = now
        unlockedAt = store.isLocked ? nil : now()
        timeout = store.settings.vaultTimeout

        applicationNotifications.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidResignActive() }
            }
            .store(in: &subscriptions)
        applicationNotifications.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            }
            .store(in: &subscriptions)

        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ] {
            workspaceNotifications.publisher(for: name)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.lockForSystemEvent() }
                }
                .store(in: &subscriptions)
        }

        // macOS also broadcasts this distributed notification on screen lock.
        // It supplements the documented workspace notifications above; it is
        // never the only protection against sleep or an inactive user session.
        screenLockNotifications.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.lockForSystemEvent() }
            }
            .store(in: &subscriptions)

        store.$settings.map(\.vaultTimeout).removeDuplicates()
            .sink { [weak self] timeout in
                guard let self else { return }
                self.timeout = timeout
                self.checkInactivity()
            }
            .store(in: &subscriptions)

        store.$isLocked.removeDuplicates()
            .sink { [weak self] locked in
                guard let self else { return }
                self.unlockedAt = locked ? nil : self.now()
            }
            .store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.checkInactivity() }
            .store(in: &subscriptions)

        Publishers.CombineLatest(
            store.$settings.map(\.backgroundRefresh).removeDuplicates(),
            store.$authenticatedSession.map { $0 != nil }.removeDuplicates()
        )
        .sink { refreshEnabled, authenticated in
            if refreshEnabled && authenticated {
                BackgroundSyncManager.schedule()
            } else {
                BackgroundSyncManager.cancelPendingRefresh()
            }
        }
        .store(in: &subscriptions)
    }

    private func applicationDidResignActive() {
        guard !applicationIsActive(), store.isAuthenticated, !store.isLocked else { return }
        if timeout == .immediately { store.lock(requestAutomaticUnlock: false) }
    }

    private func applicationDidBecomeActive() {
        checkInactivity()
        Task { await store.refreshAfterBecomingActive() }
    }

    /// Timed modes measure session input inactivity, independent of app focus.
    /// Unlocking starts a fresh interval even if the Mac had already been idle.
    func checkInactivity() {
        guard store.isAuthenticated, !store.isLocked else { return }
        if timeout == .immediately {
            if !applicationIsActive() { store.lock(requestAutomaticUnlock: false) }
            return
        }
        guard let interval = timeout.timeInterval, let unlockedAt else { return }
        let elapsed = max(0, now().timeIntervalSince(unlockedAt))
        if min(idleSeconds(), elapsed) >= interval {
            store.lock(requestAutomaticUnlock: false)
        }
    }

    private func lockForSystemEvent() {
        guard store.isAuthenticated else { return }
        // Waking or dismissing the system lock screen must not start a new
        // biometric prompt before the user explicitly unlocks their vault.
        if !store.isLocked || store.shouldAutomaticallyPromptUnlock {
            store.lock(requestAutomaticUnlock: false)
        }
    }
}
#endif
