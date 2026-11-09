import Foundation
import LocalAuthentication
import SwiftUI

/// Settings > "Authenticate before reveal or copy". One successful check covers
/// the next minute, so copying a user name and then its password asks once.
/// Locking or leaving the app ends it early.
enum VaultSensitiveAccess {
    static let gracePeriod: TimeInterval = 60

    private static var authorizedUntil: Date?
    private static var pending: Task<Bool, Never>?

    static func authorize(_ store: AppStore) async -> Bool {
        guard !store.isLocked, store.isAuthenticated else { return false }
        guard store.settings.requireBiometricForSensitiveActions else { return true }
        if let authorizedUntil, authorizedUntil > .now { return true }
        if let pending {
            let generation = store.vaultGeneration
            let granted = await pending.value
            return granted && generation == store.vaultGeneration && !store.isLocked
        }

        // With nothing to authenticate with, the setting can't be honored, and
        // refusing every copy would lock the person out of their own vault.
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        let hasBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        let generation = store.vaultGeneration
        let allowPasscode = store.settings.devicePasscodeFallback || !hasBiometrics
        let task = Task<Bool, Never> {
            await BiometricAuthenticator.authenticate(
                reason: L10n.string("Show or copy a saved item"),
                allowPasscode: allowPasscode
            )
        }
        pending = task
        let granted = await task.value
        pending = nil
        guard granted, generation == store.vaultGeneration, !store.isLocked else { return false }
        authorizedUntil = Date.now.addingTimeInterval(gracePeriod)
        return true
    }

    static func markAuthorized() {
        authorizedUntil = Date.now.addingTimeInterval(gracePeriod)
    }

    static func revoke() {
        authorizedUntil = nil
    }
}

/// What the current session may do with an item, from collection permissions.
struct VaultItemPermissions {
    /// Edit, move, favorite, archive and delete. Read-only collections allow none.
    let canEdit: Bool
    /// Show and copy passwords, codes and other secrets. Collections that hide
    /// passwords allow none.
    let canRevealSecrets: Bool
    let canCopyPassword: Bool
    let canCopyCode: Bool

    init(item: VaultItem, store: AppStore) {
        let collections = item.collectionIDs.compactMap(store.collection(withID:))
        // With no known collection the server is the judge; it refuses a write it doesn't allow.
        canEdit = !store.isLocked && store.canEdit(item)
            && (collections.isEmpty || collections.contains { !$0.isReadOnly })
        canRevealSecrets = store.canRevealSecrets(of: item)
        canCopyPassword = !item.password.isEmpty && store.canCopyLoginPassword(item)
        canCopyCode = item.totpSecret?.isEmpty == false && store.canCopyVaultSecrets(item)
    }
}

extension AppStore {
    /// `canCopyVaultSecrets` refuses archived and deleted items outright, but their
    /// pages still show secrets under the same collection permission.
    func canRevealSecrets(of item: VaultItem) -> Bool {
        if canCopyVaultSecrets(item) { return true }
        guard item.isDeleted || item.isArchived else { return false }
        var active = item
        active.deletedAt = nil
        active.archivedAt = nil
        return canCopyVaultSecrets(active)
    }
}
