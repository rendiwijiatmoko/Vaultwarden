#if os(macOS)
import AppKit
import Combine
import Foundation

struct SSHAgentPrompt: Identifiable {
    let id: UUID
    let keyName: String?
    let fingerprint: String?
}

/// Vault policy and user authorization live on the main actor. The socket layer
/// sees request/response bytes only and never holds vault items or private keys.
@MainActor
final class MacSSHAgent: ObservableObject {
    private enum ApprovalDecision {
        case deny, once, always
    }

    @Published private(set) var isRunning = false
    @Published private(set) var startupFailed = false
    @Published var prompt: SSHAgentPrompt?
    let socketPath: String?
    var presentRequest: (() -> Void)?

    private let store: AppStore
    private let authorizationTimeout: Duration
    private var transport: SSHAgentSocket?
    private var subscriptions: Set<AnyCancellable> = []
    private var approval: CheckedContinuation<ApprovalDecision, Never>?
    private var approvalID: UUID?
    private var approvalKey: VaultItem?
    private var timeoutTask: Task<Void, Never>?
    private var revision: UInt64 = 0

    init(store: AppStore, socketPath: String? = nil, authorizationTimeout: Duration = .seconds(60)) {
        self.store = store
        self.authorizationTimeout = authorizationTimeout
        self.socketPath = socketPath ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.xyz.0xmwehehe.vaultwardenApp")?
            .appendingPathComponent("SSH", isDirectory: true)
            .appendingPathComponent("agent.sock").path
        store.$settings.removeDuplicates { lhs, rhs in
            (lhs.sshAgentEnabled == true) == (rhs.sshAgentEnabled == true)
                && Set(lhs.sshAgentAllowedKeyIDs ?? []) == Set(rhs.sshAgentAllowedKeyIDs ?? [])
                && (lhs.sshAgentApprovals ?? []) == (rhs.sshAgentApprovals ?? [])
        }.sink { [weak self] settings in
            guard let self else { return }
            invalidate()
            configure(enabled: settings.sshAgentEnabled == true)
        }.store(in: &subscriptions)
        store.$isLocked.sink { [weak self] locked in
            if locked { self?.invalidate() }
        }.store(in: &subscriptions)
        store.$authenticatedSession.removeDuplicates { lhs, rhs in
            lhs?.tokenReference == rhs?.tokenReference && lhs?.accountID == rhs?.accountID
                && lhs?.serverURL == rhs?.serverURL
        }.sink { [weak self] _ in
            self?.invalidate()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                configure(enabled: store.settings.sshAgentEnabled == true)
            }
        }.store(in: &subscriptions)
        store.$items.sink { [weak self] items in
            guard let self, let key = approvalKey else { return }
            // A foreground refresh republishes the list, even when the requested
            // key is unchanged. Only changes to that key invalidate approval.
            guard let updated = items.first(where: { $0.id == key.id }),
                  Self.sameAuthorizationKey(key, updated) else {
                invalidate()
                return
            }
            let requestID = approvalID
            let keyID = key.id
            // @Published sends before AppStore installs the new permission map.
            DispatchQueue.main.async { [weak self] in
                guard let self, approvalID == requestID, approvalKey != nil else { return }
                guard let current = store.items.first(where: { $0.id == keyID }),
                      store.canUseSSHKey(current) else { invalidate(); return }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.invalidate()
                self?.transport?.stop()
            }.store(in: &subscriptions)
    }

    var shellConfiguration: String {
        guard let socketPath else { return "" }
        return "export SSH_AUTH_SOCK='" + socketPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func retry() { configure(enabled: store.settings.sshAgentEnabled == true) }

    func resolvePrompt(id: UUID? = nil, approved: Bool, alwaysApprove: Bool = false) {
        if let id, id != approvalID { return }
        // Unlock requests never grant persistent signing permission.
        let decision: ApprovalDecision = !approved ? .deny
            : (alwaysApprove && approvalKey != nil ? .always : .once)
        let continuation = approval
        approval = nil
        approvalID = nil
        approvalKey = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        prompt = nil
        continuation?.resume(returning: decision)
    }

    func isAlwaysApproved(_ item: VaultItem) -> Bool {
        guard let blob = try? SSHAgentSigner.publicBlob(item.username),
              let approval = persistentApproval(for: item, blob: blob) else { return false }
        return (store.settings.sshAgentApprovals ?? []).contains(approval)
    }

    func revokeAlwaysApproval(for keyID: UUID) {
        guard let session = store.authenticatedSession else { return }
        store.settings.sshAgentApprovals?.removeAll {
            $0.accountID == session.accountID && $0.serverURL == session.serverURL && $0.keyID == keyID
        }
    }

    private func persistentApproval(for item: VaultItem, blob: Data) -> SSHAgentApproval? {
        guard let session = store.authenticatedSession else { return nil }
        return SSHAgentApproval(accountID: session.accountID, serverURL: session.serverURL,
                                keyID: item.id, fingerprint: SSHAgentSigner.fingerprint(blob))
    }

    func cancelPrompt(id: UUID) {
        guard approvalID == id else { return }
        resolvePrompt(approved: false)
    }

    private func invalidate() {
        revision &+= 1
        resolvePrompt(approved: false)
    }

    private func configure(enabled: Bool) {
        guard enabled, store.isAuthenticated else {
            transport?.stop()
            transport = nil
            isRunning = false
            startupFailed = false
            return
        }
        guard transport == nil else { return }
        guard let socketPath else { startupFailed = true; return }
        let transport = SSHAgentSocket { [weak self] request in
            guard let self else { return SSHAgentRequest.failure }
            return await self.handle(request)
        }
        do {
            try transport.start(at: socketPath)
            self.transport = transport
            isRunning = true
            startupFailed = false
        } catch {
            startupFailed = true
            isRunning = false
        }
    }

    private var eligibleItems: [(item: VaultItem, blob: Data)] {
        let allowed = Set(store.settings.sshAgentAllowedKeyIDs ?? [])
        return store.items.compactMap { item in
            guard allowed.contains(item.id), store.canUseSSHKey(item),
                  let blob = try? SSHAgentSigner.publicBlob(item.username) else { return nil }
            return (item, blob)
        }
    }

    func handle(_ payload: Data) async -> Data {
        guard isRunning, store.settings.sshAgentEnabled == true, store.isAuthenticated,
              !Task.isCancelled, let request = try? SSHAgentRequest.decode(payload) else {
            return SSHAgentRequest.failure
        }
        if case .unsupported = request { return SSHAgentRequest.failure }
        let session = store.authenticatedSession?.tokenReference
        let currentRevision = revision
        if store.isLocked {
            guard !(store.settings.sshAgentAllowedKeyIDs ?? []).isEmpty,
                  await requestApproval(keyName: nil, fingerprint: nil) != .deny,
                  isValid(revision: currentRevision, session: session), !store.isLocked else {
                return SSHAgentRequest.failure
            }
        }
        switch request {
        case .identities:
            // Keep the complete response within the frame limit, including names.
            var size = 5
            var keys: [(blob: Data, name: String)] = []
            for candidate in eligibleItems.prefix(256) {
                let name = String(candidate.item.name.prefix(256))
                size += candidate.blob.count + name.utf8.count + 8
                guard size <= SSHAgentRequest.maximumFrameSize else { break }
                keys.append((candidate.blob, name))
            }
            return SSHAgentRequest.identities(keys)
        case let .sign(blob, message, flags):
            guard let candidate = eligibleItems.first(where: { $0.blob == blob }) else {
                return SSHAgentRequest.failure
            }
            var publicReader = SSHWireReader(data: blob)
            let algorithm = try? publicReader.text()
            guard (algorithm == "ssh-ed25519" && flags == 0)
                    || (algorithm == "ssh-rsa" && [UInt32(2), 4, 6].contains(flags)) else {
                return SSHAgentRequest.failure
            }
            let decision: ApprovalDecision
            if isAlwaysApproved(candidate.item) {
                decision = .once
            } else {
                decision = await requestApproval(keyName: candidate.item.name,
                                                 fingerprint: SSHAgentSigner.fingerprint(blob), key: candidate.item)
            }
            guard decision != .deny, isValid(revision: currentRevision, session: session),
                  let current = eligibleItems.first(where: { $0.item.id == candidate.item.id && $0.blob == blob }),
                  current.item.password == candidate.item.password else { return SSHAgentRequest.failure }
            // No suspension between the final policy check and signing/returning.
            guard let signature = try? SSHAgentSigner.sign(privateKey: current.item.password, publicKey: blob,
                                                           message: message, flags: flags) else {
                return SSHAgentRequest.failure
            }
            if decision == .always, let approval = persistentApproval(for: current.item, blob: blob) {
                var approvals = store.settings.sshAgentApprovals ?? []
                approvals.removeAll {
                    $0.accountID == approval.accountID && $0.serverURL == approval.serverURL
                        && $0.keyID == approval.keyID
                }
                approvals.append(approval)
                store.settings.sshAgentApprovals = approvals
            }
            return signature
        case .unsupported: return SSHAgentRequest.failure
        }
    }

    private func isValid(revision: UInt64, session: String?) -> Bool {
        self.revision == revision && !Task.isCancelled && isRunning && !store.isLocked
            && store.settings.sshAgentEnabled == true
            && session != nil && store.authenticatedSession?.tokenReference == session
    }

    private static func sameAuthorizationKey(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.name == rhs.name
            && lhs.username == rhs.username && lhs.password == rhs.password
            && lhs.displayedSSHFingerprint == rhs.displayedSSHFingerprint
            && lhs.organization == rhs.organization && Set(lhs.collectionIDs) == Set(rhs.collectionIDs)
            && lhs.isDeleted == rhs.isDeleted && lhs.isArchived == rhs.isArchived
    }

    private func requestApproval(keyName: String?, fingerprint: String?, key: VaultItem? = nil) async -> ApprovalDecision {
        guard approval == nil, !Task.isCancelled else { return .deny }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .deny); return }
                approval = continuation
                approvalID = id
                approvalKey = key
                prompt = SSHAgentPrompt(id: id, keyName: keyName, fingerprint: fingerprint)
                presentRequest?()
                NSApplication.shared.activate(ignoringOtherApps: true)
                let timeout = authorizationTimeout
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, approvalID == id else { return }
                    resolvePrompt(approved: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, approvalID == id else { return }
                resolvePrompt(approved: false)
            }
        }
    }
}
#endif
