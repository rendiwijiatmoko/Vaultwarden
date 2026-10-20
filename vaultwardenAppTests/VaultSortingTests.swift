import Foundation
import XCTest
@testable import vaultwardenApp

@MainActor
final class VaultSortingTests: XCTestCase {
    func testCollectionsGroupByOrganizationIdentityAndKeepFallbackOrganizations() {
        let collections = [
            VaultCollection(id: "b", name: "Shared", organization: "Same name", isReadOnly: true, hidesPasswords: true, organizationID: "org2"),
            VaultCollection(id: "a", name: "Shared", organization: "Same name", isReadOnly: false, hidesPasswords: false, organizationID: "org1"),
            VaultCollection(id: "z", name: "Zulu", organization: "Same name", isReadOnly: false, hidesPasswords: false, organizationID: "org1")
        ]
        let groups = VaultCollectionGroup.grouped(collections: collections, organizations: ["Same name", "Without collections"])
        XCTAssertEqual(groups.map(\.id), ["id:org1", "id:org2", "name:Without collections"])
        XCTAssertEqual(groups[0].filters, [.collection("a"), .collection("z")])
        XCTAssertEqual(groups[1].filters, [.collection("b")])
        XCTAssertEqual(groups[2].filters, [.organization("Without collections")])
    }

    func testPasswordChangesRetainFiveMostRecentValuesAcrossOfflineEdits() {
        var previous = VaultItem(name: "Login", password: "password-0")
        for index in 1...7 {
            var edited = previous
            // An editor may have started with an older snapshot's history.
            edited.passwordHistory = nil
            edited.password = "password-\(index)"
            let date = Date(timeIntervalSince1970: Double(index))
            edited.recordPasswordChange(from: previous, at: date)
            XCTAssertEqual(edited.passwordHistory?.first?.password, previous.password)
            XCTAssertEqual(edited.passwordHistory?.first?.lastUsedDate, date)
            XCTAssertEqual(edited.passwordUpdatedAt, date)
            previous = edited
        }
        XCTAssertEqual(previous.passwordHistory?.map(\.password), ["password-6", "password-5", "password-4", "password-3", "password-2"])

        var renamed = previous
        renamed.name = "Renamed"
        renamed.recordPasswordChange(from: previous, at: .now)
        XCTAssertEqual(renamed.passwordHistory, previous.passwordHistory)
        XCTAssertEqual(renamed.passwordUpdatedAt, previous.passwordUpdatedAt)
    }

    func testPasswordHistoryIgnoresEmptyPasswordsAndOtherItemTypes() {
        for type in VaultItemType.allCases {
            let previous = VaultItem(name: "Item", password: type == .login ? "" : "private value", type: type)
            var updated = previous
            updated.password = "new value"
            updated.recordPasswordChange(from: previous, at: .now)
            XCTAssertNil(updated.passwordHistory)
        }
        let previous = VaultItem(name: "Login", password: "old password")
        var cleared = previous
        cleared.password = ""
        cleared.recordPasswordChange(from: previous, at: .now)
        XCTAssertEqual(cleared.passwordHistory?.first?.password, "old password")
        XCTAssertNotNil(cleared.passwordUpdatedAt)

        var filled = VaultItem(name: "Empty", password: "new password")
        let changedAt = Date(timeIntervalSince1970: 1234)
        filled.recordPasswordChange(from: VaultItem(name: "Empty"), at: changedAt)
        XCTAssertEqual(filled.passwordUpdatedAt, changedAt)
        XCTAssertNil(filled.passwordHistory)
    }

    func testLegacySyncHistoryAndMissingHistoryDecode() throws {
        let history = [["password": "2.synthetic-encrypted-value", "lastUsedDate": "2026-10-01T12:00:00Z"]]
        let base: [String: Any] = [
            "id": "cipher", "type": 1,
            "creationDate": "2026-10-01T12:00:00Z", "revisionDate": "2026-10-01T12:00:00Z"
        ]
        for legacy in [false, true] {
            var cipher = base
            if legacy { cipher["data"] = ["passwordHistory": history] }
            else { cipher["passwordHistory"] = history }
            let decoded = try JSONDecoder().decode(SyncCipherDTO.self, from: JSONSerialization.data(withJSONObject: cipher))
            XCTAssertEqual(decoded.passwordHistory?.first?.password, "2.synthetic-encrypted-value")
        }
        let old = try JSONDecoder().decode(SyncCipherDTO.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertNil(old.passwordHistory)
    }

    func testOlderCachesDecodeWithoutHistoryOrOrganizationID() throws {
        let item = VaultItem(name: "Old cache")
        let decoded = try JSONDecoder().decode(VaultItem.self, from: JSONEncoder().encode(item))
        XCTAssertNil(decoded.passwordHistory)
        XCTAssertNil(decoded.passwordUpdatedAt)
        let collection = try JSONDecoder().decode(VaultCollection.self, from: Data(
            #"{"id":"c","name":"Team","organization":"Company","isReadOnly":false,"hidesPasswords":false}"#.utf8
        ))
        XCTAssertNil(collection.organizationID)
        XCTAssertEqual(VaultCollectionGroup.grouped(collections: [collection], organizations: []).first?.name, "Company")
    }

    func testAlphabeticalSortingUsesNaturalOrderForItemsAndFolders() {
        let names = ["Zulu", "account 10", "Account 2", "alpha"]
        let items = names.map { VaultItem(name: $0) }
        let folders = names.map { VaultFolder(name: $0) }
        let expected = ["account 10", "Account 2", "alpha", "Zulu"]
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(expected, ["Account 2", "account 10", "alpha", "Zulu"])
        XCTAssertEqual(items.sorted(by: VaultSortOrder.nameAscending.areInIncreasingOrder).map(\.name), expected)
        XCTAssertEqual(VaultSortOrder.nameAscending.sortedFolders(folders).map(\.name), expected)
        XCTAssertEqual(items.sorted(by: VaultSortOrder.nameDescending.areInIncreasingOrder).map(\.name), Array(expected.reversed()))
        XCTAssertEqual(VaultSortOrder.nameDescending.sortedFolders(folders).map(\.name), Array(expected.reversed()))
    }

    func testDateModesKeepItemBehaviorAndServerFolderOrder() {
        let older = VaultItem(name: "Zulu", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = VaultItem(name: "Alpha", updatedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual([older, newer].sorted(by: VaultSortOrder.newestFirst.areInIncreasingOrder).map(\.id), [newer.id, older.id])
        XCTAssertEqual([newer, older].sorted(by: VaultSortOrder.oldestFirst.areInIncreasingOrder).map(\.id), [older.id, newer.id])
        let folders = [VaultFolder(name: "Zulu"), VaultFolder(name: "Alpha")]
        XCTAssertEqual(VaultSortOrder.newestFirst.sortedFolders(folders), folders)
        XCTAssertEqual(VaultSortOrder.oldestFirst.sortedFolders(folders), folders)
    }

    func testEqualNamesAndDatesHaveStableOrderAcrossSyncs() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = VaultItem(id: firstID, name: "Same", updatedAt: .distantPast)
        let second = VaultItem(id: secondID, name: "Same", updatedAt: .distantPast)
        for order in VaultSortOrder.allCases {
            XCTAssertEqual([second, first].sorted(by: order.areInIncreasingOrder).map(\.id), [firstID, secondID])
            XCTAssertFalse(order.areInIncreasingOrder(first, first))
        }
        let folders = [VaultFolder(id: secondID, name: "Same"), VaultFolder(id: firstID, name: "Same")]
        XCTAssertEqual(VaultSortOrder.nameAscending.sortedFolders(folders).map(\.id), [firstID, secondID])
    }

    func testLegacySettingsDecodeWithoutResettingOtherPreferences() throws {
        var settings = AppSettings()
        settings.email = "sorting@example.com"
        settings.theme = .dark
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "savedVaultSortOrder")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.vaultSortOrder, .newestFirst)
        XCTAssertEqual(decoded.email, settings.email)
        XCTAssertEqual(decoded.theme, .dark)
    }

    func testPreferencePersistsAcrossStoreRecreationAndSortsLiveFolders() throws {
        let suite = "VaultSortingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(settingsDefaults: defaults)
        store.settings.vaultSortOrder = .nameAscending
        let restored = AppStore(settingsDefaults: defaults)
        XCTAssertEqual(restored.settings.vaultSortOrder, .nameAscending)
        restored.folders = [VaultFolder(name: "Zulu"), VaultFolder(name: "Alpha")]
        XCTAssertEqual(restored.sortedFolders.map(\.name), ["Alpha", "Zulu"])
        restored.folders.append(VaultFolder(name: "Beta"))
        XCTAssertEqual(restored.sortedFolders.map(\.name), ["Alpha", "Beta", "Zulu"])
        restored.settings.vaultSortOrder = .nameDescending
        XCTAssertEqual(restored.sortedFolders.map(\.name), ["Zulu", "Beta", "Alpha"])
        XCTAssertEqual(AppStore(settingsDefaults: defaults).settings.vaultSortOrder, .nameDescending)
    }
}
