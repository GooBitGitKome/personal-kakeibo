import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class WidgetEntryTests: XCTestCase {
    @MainActor private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        return try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private var now: Date { Month.calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))! }

    func testKeypadRejectsOverflowAndNormalizesLeadingZeroes() throws {
        var state = WidgetEntryState()
        try state.append("00"); XCTAssertEqual(state.amount, "")
        try state.append("1"); try state.append("00"); XCTAssertEqual(state.amount, "100")
        state.amount = String(Int64.max)
        XCTAssertThrowsError(try state.append("0"))
        XCTAssertEqual(state.amount, String(Int64.max))
        XCTAssertThrowsError(try state.append("-"))
    }

    @MainActor func testRegistrationUndoAndStaleReplayForEveryPaymentAccountKind() throws {
        for kind: AccountKind? in [nil, .cash, .bank, .creditCard] {
            let store = Store(container: try container()); try store.seed()
            let device = UUID()
            var state = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
            let session = state.sessionID
            let useCases = WidgetEntryUseCases(repository: store)
            if let kind {
                let account = FinanceAccount(name: "支払元", kind: kind, openingDate: now, openingBalance: 10_000)
                try FinanceUseCases(repository: store).saveAccount(account)
                try useCases.perform(.selectAccount, value: account.id.uuidString, sessionID: session, deviceID: device, now: now)
            }
            try useCases.perform(.digit, value: "8", sessionID: session, deviceID: device, now: now)
            try useCases.perform(.digit, value: "00", sessionID: session, deviceID: device, now: now)
            try useCases.perform(.save, sessionID: session, deviceID: device, now: now)
            try useCases.perform(.save, sessionID: session, deviceID: device, now: now)
            let saved = try store.snapshot()
            XCTAssertEqual(saved.transactions.count, 1)
            XCTAssertEqual(saved.transactions.first?.id, session)
            XCTAssertEqual(saved.transactions.first?.amount, 800)
            XCTAssertEqual(saved.transactions.first?.occurredAt, now)
            XCTAssertEqual(saved.transactions.first?.source, .manual)
            XCTAssertEqual(saved.finance.postings.count, kind == nil ? 0 : 1)
            if let kind {
                XCTAssertEqual(saved.finance.postings.first?.amount, kind == .creditCard ? 800 : -800)
            }
            let reopened = Store(container: store.container)
            state = try reopened.widgetState(deviceID: device)
            XCTAssertEqual(state.mode, .saved)
            try WidgetEntryUseCases(repository: reopened).perform(.undo, sessionID: session, deviceID: device, now: now)
            XCTAssertTrue(try reopened.snapshot().transactions.isEmpty)
            XCTAssertTrue(try reopened.snapshot().finance.postings.isEmpty)
            state = try reopened.widgetState(deviceID: device)
            XCTAssertEqual(state.amount, "800")
            XCTAssertNotEqual(state.sessionID, session)
            XCTAssertThrowsError(try useCases.perform(.save, sessionID: session, deviceID: device, now: now))
            XCTAssertThrowsError(try useCases.perform(.undo, sessionID: session, deviceID: device, now: now))
            XCTAssertTrue(try reopened.snapshot().transactions.isEmpty)
        }
    }

    @MainActor func testFailedSavePreservesDraftAndEditedTransactionCannotBeUndone() throws {
        var failing = false
        let store = Store(container: try container(), beforeSave: { if failing { throw StoreError.conflict } })
        try store.seed()
        let device = UUID()
        let state = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
        let useCases = WidgetEntryUseCases(repository: store)
        try useCases.perform(.digit, value: "5", sessionID: state.sessionID, deviceID: device, now: now)
        let draft = try store.widgetState(deviceID: device)
        let original = try store.snapshot()
        failing = true
        XCTAssertThrowsError(try useCases.perform(.save, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertEqual(try store.snapshot(), original)
        XCTAssertEqual(try store.widgetState(deviceID: device), draft)
        failing = false
        try useCases.perform(.save, sessionID: state.sessionID, deviceID: device, now: now)
        var transaction = try XCTUnwrap(store.snapshot().transactions.first)
        transaction.memo = "アプリで編集"; transaction.updatedAt = now.addingTimeInterval(1)
        try store.save(transaction)
        XCTAssertThrowsError(try useCases.perform(.undo, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertEqual(try store.snapshot().transactions, [transaction])
    }

    @MainActor func testArchivedCategoryAndAccountDoNotSilentlyChangeSelection() throws {
        let store = Store(container: try container()); try store.seed()
        let device = UUID(); let state = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
        let useCases = WidgetEntryUseCases(repository: store)
        try useCases.perform(.digit, value: "1", sessionID: state.sessionID, deviceID: device, now: now)
        let category = try XCTUnwrap(state.categoryID)
        try store.setArchived(id: category, archived: true)
        XCTAssertThrowsError(try useCases.perform(.save, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertTrue(try store.snapshot().transactions.isEmpty)
        try store.setArchived(id: category, archived: false)
        var account = FinanceAccount(name: "銀行", kind: .bank, openingDate: now, openingBalance: 0)
        try FinanceUseCases(repository: store).saveAccount(account)
        try useCases.perform(.selectAccount, value: account.id.uuidString, sessionID: state.sessionID, deviceID: device, now: now)
        account.isArchived = true; try FinanceUseCases(repository: store).saveAccount(account)
        XCTAssertThrowsError(try useCases.perform(.save, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertEqual(try store.widgetState(deviceID: device).accountID, account.id)
        XCTAssertTrue(try store.snapshot().transactions.isEmpty)
    }

    @MainActor func testFailedUndoRollsBackPostingAndKeepsReceipt() throws {
        var failing = false
        let store = Store(container: try container(), beforeSave: { if failing { throw StoreError.conflict } })
        try store.seed()
        let card = FinanceAccount(name: "カード", kind: .creditCard, openingDate: now, openingBalance: 0)
        try FinanceUseCases(repository: store).saveAccount(card)
        let device = UUID(); let state = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
        let actions = WidgetEntryUseCases(repository: store)
        try actions.perform(.selectAccount, value: card.id.uuidString, sessionID: state.sessionID, deviceID: device, now: now)
        try actions.perform(.digit, value: "7", sessionID: state.sessionID, deviceID: device, now: now)
        try actions.perform(.save, sessionID: state.sessionID, deviceID: device, now: now)
        let original = try store.snapshot(); let receipt = try store.widgetState(deviceID: device)
        failing = true
        XCTAssertThrowsError(try actions.perform(.undo, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertEqual(try store.snapshot(), original)
        XCTAssertEqual(try store.widgetState(deviceID: device), receipt)
        failing = false
        try actions.perform(.next, sessionID: state.sessionID, deviceID: device, now: now)
        let next = try store.widgetState(deviceID: device)
        XCTAssertNotEqual(next.sessionID, state.sessionID)
        XCTAssertEqual(next.amount, "")
        XCTAssertEqual(next.accountID, card.id)
        XCTAssertEqual(next.categoryID, state.categoryID)
        XCTAssertThrowsError(try actions.perform(.undo, sessionID: state.sessionID, deviceID: device, now: now))
        XCTAssertTrue(BackupFormat.equivalent(try BackupFormat.decode(BackupFormat.encode(original)), original))
    }

    @MainActor func testPageSelectionAndBackKeepDraft() throws {
        let store = Store(container: try container()); try store.seed()
        for index in 0..<8 {
            try FinanceUseCases(repository: store).saveAccount(FinanceAccount(name: "口座\(index)", kind: .cash,
                openingDate: now, openingBalance: 0))
        }
        let device = UUID(); let initial = try store.initializeWidgetState(deviceID: device, defaultCategoryID: nil)
        let actions = WidgetEntryUseCases(repository: store)
        try actions.perform(.digit, value: "9", sessionID: initial.sessionID, deviceID: device, now: now)
        try actions.perform(.categories, sessionID: initial.sessionID, deviceID: device, now: now)
        try actions.perform(.nextPage, sessionID: initial.sessionID, deviceID: device, now: now)
        XCTAssertEqual(try store.widgetState(deviceID: device).page, 1)
        let category = try XCTUnwrap(store.categories(type: .expense).last)
        try actions.perform(.selectCategory, value: category.id.uuidString, sessionID: initial.sessionID, deviceID: device, now: now)
        try actions.perform(.accounts, sessionID: initial.sessionID, deviceID: device, now: now)
        try actions.perform(.nextPage, sessionID: initial.sessionID, deviceID: device, now: now)
        XCTAssertEqual(try store.widgetState(deviceID: device).page, 1)
        try actions.perform(.back, sessionID: initial.sessionID, deviceID: device, now: now)
        XCTAssertEqual(try store.widgetState(deviceID: device).amount, "9")
        XCTAssertEqual(try store.widgetState(deviceID: device).categoryID, category.id)
        XCTAssertTrue(try store.snapshot().transactions.isEmpty)
    }

    #if os(macOS)
    func testOtherProcessCannotEnterStoreLockWhileWriterIsActive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("store.lock")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); time.sleep(20)", lock.path]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertEqual(String(data: try XCTUnwrap(output.fileHandleForReading.read(upToCount: 6)), encoding: .utf8), "ready\n")
        var entered = false
        XCTAssertThrowsError(try SharedStoreLock.withLock(at: lock) { entered = true })
        XCTAssertFalse(entered)
        process.terminate(); process.waitUntilExit()
        try SharedStoreLock.withLock(at: lock) { entered = true }
        XCTAssertTrue(entered)
    }
    #endif

    @MainActor func testLegacyMigrationRetryAndCrossContainerConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.store")
        let shared = root.appendingPathComponent("shared")
        let schema = Schema(versionedSchema: KakeiboSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, url: legacy, cloudKitDatabase: .none)
        let oldContainer = try ModelContainer(for: schema, migrationPlan: KakeiboLegacyMigrationPlan.self,
                                               configurations: configuration)
        let old = Store(container: oldContainer); try old.seed()
        let category = try XCTUnwrap(old.categories(type: .expense).first)
        try old.save(Transaction(type: .expense, amount: 123, categoryId: category.id, occurredAt: now, isSavingsEligible: true))
        try old.save(Budget(monthKey: Month(date: now).key, amount: 50_000))
        let finance = FinanceUseCases(repository: old)
        try finance.saveAccount(FinanceAccount(name: "移行口座", kind: .bank, openingDate: now, openingBalance: 50_000))
        try finance.saveContract(FinanceContract(name: "移行サブスク", kind: .subscription,
            categoryId: category.id, expectedAmount: 500, startDate: now, firstDueDate: now), effectiveFrom: now)
        try finance.saveAsset(OwnedAsset(name: "移行所有物", purchaseDate: now, purchasePrice: 10_000, usefulMonths: 12))
        let original = try old.snapshot()
        XCTAssertThrowsError(try SharedStore.open(root: shared, legacyURL: legacy, isWidget: true))
        XCTAssertThrowsError(try SharedStore.open(root: shared, legacyURL: legacy, isWidget: false,
                                                beforeReady: { throw StoreError.conflict }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("ready.json").path))
        XCTAssertEqual(try old.snapshot(), original)
        let first = try SharedStore.open(root: shared, legacyURL: legacy, isWidget: false)
        XCTAssertTrue(BackupFormat.equivalent(try first.store.snapshot(), original))
        let widget = try SharedStore.open(root: shared, legacyURL: legacy, isWidget: true)
        let state = try widget.store.initializeWidgetState(deviceID: widget.ready.deviceID, defaultCategoryID: nil)
        let stale = try first.store.snapshot()
        let useCases = WidgetEntryUseCases(repository: widget.store)
        try useCases.perform(.digit, value: "9", sessionID: state.sessionID, deviceID: widget.ready.deviceID, now: now)
        try useCases.perform(.save, sessionID: state.sessionID, deviceID: widget.ready.deviceID, now: now)
        XCTAssertThrowsError(try first.store.apply(stale, expecting: stale))
        XCTAssertEqual(try first.store.snapshot().transactions.count, 2)
        XCTAssertEqual(try old.snapshot(), original)
        XCTAssertEqual(try first.store.snapshot().categories.sorted { $0.id.uuidString < $1.id.uuidString },
                       original.categories.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}
