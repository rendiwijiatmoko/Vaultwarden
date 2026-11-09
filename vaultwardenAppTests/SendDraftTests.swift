import Foundation
import Testing
@testable import vaultwardenApp

@Suite("Send drafts")
struct SendDraftTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func existingSend() -> SendItem {
        SendItem(
            name: "Wi-Fi",
            kind: .text,
            text: "secret",
            accessCount: 2,
            maximumAccessCount: 5,
            expiresAt: now.addingTimeInterval(3 * 86_400),
            deletesAt: now.addingTimeInterval(10 * 86_400),
            passwordProtected: true,
            isDisabled: false
        )
    }

    @Test func editingWithoutChangesKeepsDates() {
        let send = existingSend()
        // Opened a day later, which the old form turned into new dates.
        let draft = SendDraft(editing: send, now: now.addingTimeInterval(86_400))
        let saved = draft.makeSend(id: send.id, existing: send, fileName: nil, fileSize: nil)

        #expect(saved.deletesAt == send.deletesAt)
        #expect(saved.expiresAt == send.expiresAt)
        #expect(saved.maximumAccessCount == 5)
        #expect(saved.accessCount == 2)
        #expect(!saved.isDisabled)
    }

    @Test func newDraftDefaultsToSevenDaysWithoutExpiration() {
        let draft = SendDraft(now: now)
        #expect(draft.deletionDate == now.addingTimeInterval(7 * 86_400))
        #expect(draft.effectiveExpiration == nil)
    }

    @Test func expirationNeverPassesDeletion() {
        var draft = SendDraft(now: now)
        draft.expires = true
        draft.expirationDate = draft.deletionDate.addingTimeInterval(86_400)
        #expect(draft.effectiveExpiration == draft.deletionDate)
    }

    @Test func deletionRangeStopsAtThirtyOneDays() {
        let range = SendDraft.deletionRange(now: now)
        #expect(range.lowerBound == now)
        #expect(range.upperBound == now.addingTimeInterval(31 * 86_400))
    }

    @Test func pastDeletionDateStaysSelectable() {
        let past = now.addingTimeInterval(-86_400)
        #expect(SendDraft.deletionRange(now: now, current: past).contains(past))
    }

    @Test func passwordChangesWhileEditing() {
        let send = existingSend()
        var draft = SendDraft(editing: send, now: now)
        #expect(draft.passwordUpdate(existing: send) == .preserve)

        draft.password = "new"
        #expect(draft.passwordUpdate(existing: send) == .set("new"))

        draft.requiresPassword = false
        #expect(draft.passwordUpdate(existing: send) == .remove)
    }

    @Test func validation() {
        var draft = SendDraft(now: now)
        #expect(!draft.isValid(existing: nil, hasNewFile: false, hasFileName: false))

        draft.name = "  Note "
        draft.text = "hello"
        #expect(draft.isValid(existing: nil, hasNewFile: false, hasFileName: false))

        draft.requiresPassword = true
        #expect(!draft.isValid(existing: nil, hasNewFile: false, hasFileName: false))

        draft.kind = .file
        draft.password = "pw"
        #expect(!draft.isValid(existing: nil, hasNewFile: false, hasFileName: true))
        #expect(draft.isValid(existing: nil, hasNewFile: true, hasFileName: true))
        #expect(draft.makeSend(id: UUID(), existing: nil, fileName: "a.txt", fileSize: nil).name == "Note")
    }
}
