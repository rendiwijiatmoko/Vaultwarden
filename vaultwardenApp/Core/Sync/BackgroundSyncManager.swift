import BackgroundTasks
import Foundation

nonisolated enum BackgroundSyncManager {
    static let refreshIdentifier = "xyz.0xmwehehe.vaultwardenApp.sync-refresh"

    static func register(handler: @escaping @MainActor @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule()
            let operation = Task { @MainActor in
                let success = await handler()
                if !Task.isCancelled { refreshTask.setTaskCompleted(success: success) }
            }
            refreshTask.expirationHandler = { operation.cancel() }
        }
    }

    static func schedule(earliest: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SecureLog.failure("Background task scheduling", error: error, logger: SecureLog.background)
        }
    }

    static func cancelPendingRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
    }
}
