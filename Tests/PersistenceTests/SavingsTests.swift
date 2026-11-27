import XCTest
import Foundation
import SwiftData
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class SavingsTests: XCTestCase {
    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let result = Store(container: try ModelContainer(for: schema, configurations: config))
        try result.seed(); return result
    }
    @MainActor func testSaveResetsFlagAndConfiguredCategoryOnlyAfterSuccess() throws {
        let store = try store()
        let suite = "savings.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DevicePreferences(defaults: defaults)
        let model = KakeiboViewModel(store: store, preferences: preferences, reminderService: FakeReminders())
        let first = try XCTUnwrap(model.choices.first?.id)
        let last = try XCTUnwrap(model.choices.last?.id)
        XCTAssertNotEqual(first, last)
        model.setDefaultCategory(first)
        model.categoryId = last; model.amount = "1250"; model.isSavingsEligible = true
        model.save()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isSavingsEligible); XCTAssertEqual(model.categoryId, first)
        XCTAssertEqual(model.amount, "")
        let saved = try XCTUnwrap(store.allTransactions().first)
        XCTAssertTrue(saved.isSavingsEligible); XCTAssertEqual(saved.categoryId, last)
        model.amount = "250"; model.save()
        XCTAssertEqual(try store.allTransactions().filter(\.isSavingsEligible).count, 1)
        let failing = KakeiboViewModel(store: Store(container: store.container, beforeSave: { throw StoreError.conflict }), preferences: preferences, reminderService: FakeReminders())
        failing.categoryId = last; failing.amount = "900"; failing.isSavingsEligible = true
        failing.save()
        XCTAssertNotNil(failing.error); XCTAssertEqual(failing.amount, "900")
        XCTAssertTrue(failing.isSavingsEligible); XCTAssertEqual(failing.categoryId, last)
        XCTAssertEqual(try store.allTransactions().count, 2)
    }
    @MainActor func testV2MigrationAndFlagSurvivesDiskReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let category = PersonalKakeiboDomain.Category(name: "食費", type: .expense)
        let entry = Transaction(type: .expense, amount: 200, categoryId: category.id, occurredAt: Date())
        do {
            let schema = Schema(versionedSchema: KakeiboSchemaV2.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(StoredCategory(category)); context.insert(StoredTransaction(entry)); try context.save()
        }
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let store = Store(container: try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: config))
            var migrated = try XCTUnwrap(store.allTransactions().first)
            XCTAssertEqual(migrated, entry); XCTAssertFalse(migrated.isSavingsEligible)
            migrated.isSavingsEligible = true; try store.save(migrated)
        }
        let reopened = Store(container: try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        let persisted = try XCTUnwrap(reopened.allTransactions().first)
        XCTAssertTrue(persisted.isSavingsEligible); XCTAssertEqual(persisted.id, entry.id)
        XCTAssertEqual(persisted.amount, entry.amount); XCTAssertEqual(persisted.categoryId, entry.categoryId)
    }
    @MainActor func testFlagEditingBackupRestoreLegacyAndCSV() throws {
        let store = try store()
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        var entry = Transaction(type: .expense, amount: 300, categoryId: category.id, occurredAt: Date(), isSavingsEligible: true)
        try store.save(entry)
        var snapshot = try store.snapshot()
        let encoded = try BackupFormat.encode(snapshot)
        let decoded = try BackupFormat.decode(encoded)
        XCTAssertTrue(try XCTUnwrap(decoded.transactions.first).isSavingsEligible)
        XCTAssertTrue(String(decoding: try BackupFormat.csv(snapshot), as: UTF8.self).contains("isSavingsEligible"))
        entry.isSavingsEligible = false; try store.save(entry)
        XCTAssertFalse(try XCTUnwrap(store.allTransactions().first).isSavingsEligible)
        let preview = try BackupFormat.preview(decoded, current: store.snapshot(), overwrite: true)
        try store.apply(preview.merged, expecting: preview.original)
        XCTAssertTrue(try XCTUnwrap(store.allTransactions().first).isSavingsEligible)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        transactions[0].removeValue(forKey: "isSavingsEligible"); object["transactions"] = transactions
        snapshot = try BackupFormat.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(try XCTUnwrap(snapshot.transactions.first).isSavingsEligible)
        transactions[0]["isSavingsEligible"] = "true"; object["transactions"] = transactions
        XCTAssertThrowsError(try BackupFormat.decode(JSONSerialization.data(withJSONObject: object)))
        try store.delete(id: entry.id)
        XCTAssertTrue(try ModelContext(store.container).fetch(FetchDescriptor<StoredSavingsFlag>()).isEmpty)
    }
}
