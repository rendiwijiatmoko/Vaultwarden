import Foundation

/// The editable state of a Send, kept apart from the form so the rules
/// (lifetime limits, what an edit keeps, password changes) are testable.
///
/// Editing keeps the Send's existing deletion and expiration dates unless the
/// person changes them. The previous form recomputed both from "now" on every
/// save, so renaming a Send silently moved its deletion date.
nonisolated struct SendDraft: Equatable, Sendable {
    /// Vaultwarden rejects deletion dates more than 31 days out.
    static let maximumLifetime: TimeInterval = 31 * 86_400
    static let defaultLifetime: TimeInterval = 7 * 86_400
    static let defaultExpiration: TimeInterval = 86_400
    static let accessCountRange: ClosedRange<Int> = 1...1_000

    var kind: SendKind = .text
    var name = ""
    var text = ""
    var deletionDate: Date
    var expires = false
    var expirationDate: Date
    var limitsAccess = false
    var maximumAccessCount = 10
    var requiresPassword = false
    var password = ""
    var isActive = true

    init(editing send: SendItem? = nil, now: Date = Date()) {
        let deletion = send?.deletesAt ?? now.addingTimeInterval(Self.defaultLifetime)
        kind = send?.kind ?? .text
        name = send?.name ?? ""
        text = send?.text ?? ""
        deletionDate = deletion
        expires = send?.expiresAt != nil
        expirationDate = send?.expiresAt ?? min(now.addingTimeInterval(Self.defaultExpiration), deletion)
        limitsAccess = send?.maximumAccessCount != nil
        maximumAccessCount = send?.maximumAccessCount ?? 10
        requiresPassword = send?.passwordProtected ?? false
        isActive = !(send?.isDisabled ?? false)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The dates a person can pick. An existing Send that is already past its
    /// date keeps that date selectable so opening the editor changes nothing.
    static func deletionRange(now: Date, current: Date? = nil) -> ClosedRange<Date> {
        let lower = min(now, current ?? now)
        return lower...max(lower, now.addingTimeInterval(maximumLifetime))
    }

    func expirationRange(now: Date, current: Date? = nil) -> ClosedRange<Date> {
        let lower = min(now, current ?? now)
        return lower...max(lower, deletionDate)
    }

    /// A Send can't stay reachable after it is deleted, so expiration never
    /// passes the deletion date.
    var effectiveExpiration: Date? {
        expires ? min(expirationDate, deletionDate) : nil
    }

    func isValid(existing: SendItem?, hasNewFile: Bool, hasFileName: Bool) -> Bool {
        guard !trimmedName.isEmpty else { return false }
        switch kind {
        case .text:
            guard !text.isEmpty else { return false }
        case .file:
            guard hasFileName, existing != nil || hasNewFile else { return false }
        }
        return !requiresPassword || existing?.passwordProtected == true || !password.isEmpty
    }

    func makeSend(id: UUID, existing: SendItem?, fileName: String?, fileSize: String?) -> SendItem {
        SendItem(
            id: id,
            name: trimmedName,
            kind: kind,
            text: text,
            fileName: fileName,
            fileID: existing?.fileID,
            fileSize: existing?.fileSize ?? fileSize,
            accessCount: existing?.accessCount ?? 0,
            maximumAccessCount: limitsAccess ? min(max(maximumAccessCount, Self.accessCountRange.lowerBound), Self.accessCountRange.upperBound) : nil,
            expiresAt: effectiveExpiration,
            deletesAt: deletionDate,
            passwordProtected: requiresPassword,
            isDisabled: !isActive,
            shareURL: existing?.shareURL
        )
    }

    /// An empty password field while editing keeps the current password.
    func passwordUpdate(existing: SendItem?) -> SendPasswordUpdate {
        guard let existing else { return requiresPassword ? .set(password) : .preserve }
        if existing.passwordProtected, !requiresPassword { return .remove }
        if requiresPassword, !password.isEmpty { return .set(password) }
        return .preserve
    }
}
