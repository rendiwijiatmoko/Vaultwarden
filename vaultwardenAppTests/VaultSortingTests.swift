import Foundation
import XCTest
@testable import vaultwardenApp

@MainActor
final class VaultSortingTests: XCTestCase {
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
