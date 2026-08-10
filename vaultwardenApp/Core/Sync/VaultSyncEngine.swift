import Foundation

nonisolated struct SyncFlushResult: Sendable {
    var completed = 0
    var completedMutationIDs: [UUID] = []
    var deferred = 0
    var conflicted = 0
    var failed = 0
    var removedTerminalMutations = 0
    var failureMessages: [String] = []

    var madeServerChanges: Bool { completed > 0 }
    var hasProblems: Bool { conflicted > 0 || failed > 0 }

    var problemNotice: String? {
        if conflicted > 0 {
            return "A server revision conflict was detected. Your local copy is preserved and can be retried."
        }
        guard failed > 0 else { return nil }
        if let message = failureMessages.first, !message.isEmpty {
            return "A change could not be saved: \(message)"
        }
        return "A change could not be saved by the server."
    }
}

actor VaultSyncEngine {
    private let service: any VaultwardenService
    private let queue: SyncMutationQueue

    init(service: any VaultwardenService, queue: SyncMutationQueue = SyncMutationQueue()) {
        self.service = service
        self.queue = queue
    }

    func enqueue(_ mutation: PreparedVaultMutation) async throws {
        try await queue.enqueue(mutation)
    }

    func mutations(reference: String) async throws -> [PreparedVaultMutation] {
        try await queue.all(reference: reference)
    }

    func pendingCount(reference: String) async throws -> Int {
        try await queue.all(reference: reference).count
    }

    func nextRetryDate(reference: String) async throws -> Date? {
        try await queue.all(reference: reference)
            .filter { $0.state == .pending }
            .map(\.nextAttemptAt)
            .min()
    }

    func retryBlocked(reference: String) async throws {
        try await queue.resetBlocked(reference: reference)
    }

    func clear(reference: String) async throws {
        try await queue.delete(reference: reference)
    }

    func flush(session: AuthenticatedSession) async -> SyncFlushResult {
        var result = SyncFlushResult()
        let ready: [PreparedVaultMutation]
        do {
            ready = try await queue.ready(reference: session.tokenReference)
        } catch {
            result.failed += 1
            result.failureMessages.append("The encrypted offline queue could not be read.")
            return result
        }

        for var mutation in ready {
            if Task.isCancelled { break }
            do {
                try await service.executeMutation(mutation, session: session)
                try await queue.remove(id: mutation.id, reference: session.tokenReference)
                result.completed += 1
                result.completedMutationIDs.append(mutation.id)
            } catch {
                if Self.isRevisionConflict(error), mutation.revisionRetryCount < 2 {
                    do {
                        mutation = try await service.rebaseMutation(mutation, session: session)
                        mutation.revisionRetryCount += 1
                        mutation.nextAttemptAt = Date()
                        try await queue.update(mutation)
                        try await service.executeMutation(mutation, session: session)
                        try await queue.remove(id: mutation.id, reference: session.tokenReference)
                        result.completed += 1
                        result.completedMutationIDs.append(mutation.id)
                        continue
                    } catch {
                        if Self.isRevisionConflict(error) {
                            mutation.state = .conflicted
                            mutation.lastError = error.localizedDescription
                            try? await queue.update(mutation)
                            result.conflicted += 1
                            result.failureMessages.append(error.localizedDescription)
                            continue
                        }
                        await deferOrFail(error: error, mutation: &mutation, result: &result)
                        continue
                    }
                }
                await deferOrFail(error: error, mutation: &mutation, result: &result)
            }
        }
        return result
    }

    private func deferOrFail(
        error: Error,
        mutation: inout PreparedVaultMutation,
        result: inout SyncFlushResult
    ) async {
        mutation.lastError = error.localizedDescription
        if Self.isUnsupportedArchiveFailure(error) {
            try? await queue.remove(id: mutation.id, reference: mutation.accountReference)
            result.failed += 1
            result.removedTerminalMutations += 1
            result.failureMessages.append(error.localizedDescription)
            return
        }
        if Self.isRetryableSyncFailure(error) {
            mutation.attemptCount += 1
            mutation.nextAttemptAt = Date().addingTimeInterval(Self.retryDelay(attempt: mutation.attemptCount))
            mutation.state = .pending
            result.deferred += 1
        } else if Self.isRevisionConflict(error) {
            mutation.state = .conflicted
            result.conflicted += 1
            result.failureMessages.append(error.localizedDescription)
        } else {
            mutation.state = .failed
            result.failed += 1
            result.failureMessages.append(error.localizedDescription)
        }
        try? await queue.update(mutation)
    }

    private nonisolated static func isUnsupportedArchiveFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? VaultwardenServiceError,
              case .archiveNotSupported = serviceError else { return false }
        return true
    }

    private static func retryDelay(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 8)
        let base = min(5.0 * pow(2.0, Double(exponent)), 15 * 60)
        return base + Double.random(in: 0...(base * 0.2))
    }

    private nonisolated static func isRevisionConflict(_ error: Error) -> Bool {
        guard let serviceError = error as? VaultwardenServiceError,
              case let .serverRejected(status, _) = serviceError else { return false }
        return status == 409 || status == 412
    }

    private nonisolated static func isRetryableSyncFailure(_ error: Error) -> Bool {
        if let transport = error as? HTTPClientError { return transport.allowsOfflineFallback }
        guard let serviceError = error as? VaultwardenServiceError,
              case let .serverRejected(status, _) = serviceError else { return false }
        return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }
}
