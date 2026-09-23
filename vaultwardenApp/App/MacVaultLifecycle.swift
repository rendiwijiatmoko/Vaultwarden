#if os(macOS)
import AppKit
import Combine

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
    private var timeoutTask: Task<Void, Never>?
    private var inactiveSince: Date?
    private var timeout: VaultTimeout

    init(
        store: AppStore,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
        applicationNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenLockNotifications: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.store = store
        self.applicationIsActive = applicationIsActive
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
                self.scheduleTimeout()
            }
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
        guard !applicationIsActive(), inactiveSince == nil, store.isAuthenticated else { return }
        let now = Date()
        inactiveSince = now
        store.appDidEnterBackground(at: now)
        scheduleTimeout()
    }

    private func applicationDidBecomeActive() {
        timeoutTask?.cancel()
        timeoutTask = nil
        inactiveSince = nil
        Task { await store.refreshAfterBecomingActive() }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let inactiveSince,
              !applicationIsActive(),
              store.isAuthenticated,
              !store.isLocked,
              let interval = timeout.timeInterval else { return }

        let remaining = max(0, interval - Date().timeIntervalSince(inactiveSince))
        if remaining == 0 {
            store.lock()
            return
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  !applicationIsActive(), store.isAuthenticated, !store.isLocked else { return }
            store.lock()
        }
    }

    private func lockForSystemEvent() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard store.isAuthenticated else { return }
        // Waking or dismissing the system lock screen must not start a new
        // biometric prompt before the user explicitly unlocks their vault.
        if !store.isLocked || store.shouldAutomaticallyPromptUnlock {
            store.lock(requestAutomaticUnlock: false)
        }
    }
}
#endif
