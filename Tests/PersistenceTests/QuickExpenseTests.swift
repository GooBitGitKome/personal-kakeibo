import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain

final class QuickExpenseTests: XCTestCase {
    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let container = try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = Store(container: container); try store.seed(); return store
    }

    func testOnlyExplicitQuickEntryRouteIsAccepted() {
        XCTAssertTrue(QuickEntryRoute.matches(QuickEntryRoute.url))
        XCTAssertTrue(QuickEntryRoute.matches(URL(string: "personalkakeibo://quick-entry/")!))
        for url in ["https://quick-entry", "personalkakeibo://other", "personalkakeibo://quick-entry/extra",
                    "personalkakeibo://quick-entry?amount=100", "personalkakeibo://quick-entry#other",
                    "personalkakeibo://user@quick-entry", "personalkakeibo://quick-entry:80"] {
            XCTAssertFalse(QuickEntryRoute.matches(URL(string: url)!))
        }
    }

    @MainActor func testWidgetDraftIsRetainedAndFullscreenSaveUndoUsesSameReceipt() throws {
        let store = try store(); let device = UUID()
        let original = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
        try store.performWidgetAction(.digit, value: "8", sessionID: original.sessionID, deviceID: device, now: Date())
        try store.performWidgetAction(.categories, value: "", sessionID: original.sessionID, deviceID: device, now: Date())
        var commits = 0
        let entry = try QuickExpenseViewModel(store: store, deviceID: device) { commits += 1 }
        XCTAssertEqual(entry.snapshot.state.amount, "8")
        XCTAssertEqual(entry.snapshot.state.mode, .keypad)
        XCTAssertEqual(entry.snapshot.state.sessionID, original.sessionID)
        entry.perform(.digit, value: "00")
        entry.perform(.save)
        XCTAssertNil(entry.error); XCTAssertEqual(commits, 1)
        XCTAssertEqual(try store.snapshot().transactions.first?.amount, 800)
        XCTAssertEqual(entry.snapshot.state.mode, .saved)
        entry.perform(.undo)
        XCTAssertNil(entry.error); XCTAssertEqual(commits, 2)
        XCTAssertTrue(try store.snapshot().transactions.isEmpty)
        XCTAssertEqual(entry.snapshot.state.amount, "800")
        XCTAssertNotEqual(entry.snapshot.state.sessionID, original.sessionID)
        let reopened = try QuickExpenseViewModel(store: store, deviceID: device)
        XCTAssertEqual(reopened.snapshot.state.amount, "800")
    }

    @MainActor func testOpeningAfterSaveBeginsNewDraftAndKeepsExistingExpense() throws {
        let store = try store(); let device = UUID()
        let entry = try QuickExpenseViewModel(store: store, deviceID: device)
        entry.perform(.digit, value: "5"); entry.perform(.save)
        let saved = try store.snapshot()
        let category = entry.snapshot.state.categoryID
        let reopened = try QuickExpenseViewModel(store: store, deviceID: device)
        XCTAssertEqual(reopened.snapshot.state.mode, .keypad)
        XCTAssertEqual(reopened.snapshot.state.amount, "")
        XCTAssertEqual(reopened.snapshot.state.categoryID, category)
        XCTAssertEqual(try store.snapshot(), saved)
        XCTAssertFalse(reopened.snapshot.canSave)
    }

    @MainActor func testInvalidatedSelectionRefreshesChoicesWithoutLosingAmount() throws {
        let store = try store(); let entry = try QuickExpenseViewModel(store: store, deviceID: UUID())
        entry.perform(.digit, value: "9")
        let category = try XCTUnwrap(entry.snapshot.state.categoryID)
        try store.setArchived(id: category, archived: true)
        entry.perform(.save)
        XCTAssertNotNil(entry.error)
        XCTAssertEqual(entry.snapshot.state.amount, "9")
        XCTAssertFalse(entry.snapshot.canSave)
        XCTAssertFalse(entry.snapshot.categories.contains { $0.id == category })
        XCTAssertTrue(try store.snapshot().transactions.isEmpty)
    }
}
