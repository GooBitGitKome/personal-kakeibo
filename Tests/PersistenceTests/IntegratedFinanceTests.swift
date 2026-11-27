import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class IntegratedFinanceTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
            cloudKitDatabase: .none)
        let value = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        try value.seed()
        return value
    }

    @MainActor func testSubscriptionBatchIsAtomicAndIdempotent() throws {
        let store = try store()
        let useCases = FinanceUseCases(repository: store)
        let start = date(2026, 10, 1)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        for name in ["動画", "音楽"] {
            let contract = FinanceContract(name: name, kind: .subscription,
                categoryId: category.id, expectedAmount: 1_000, startDate: start, firstDueDate: start)
            try useCases.saveContract(contract, effectiveFrom: start)
        }
        let original = try store.snapshot()
        let payments = original.finance.payments.filter { Month(date: start).range.contains($0.dueDate) }
        XCTAssertEqual(payments.count, 2)
        var stale = payments
        stale[1].expectedAmount += 1
        XCTAssertThrowsError(try useCases.recordSubscriptions(stale, month: Month(date: start)))
        XCTAssertEqual(try store.snapshot(), original)
        try useCases.recordSubscriptions(payments, month: Month(date: start))
        let recorded = try store.snapshot()
        XCTAssertEqual(recorded.transactions.count, 2)
        XCTAssertEqual(recorded.finance.payments.filter { $0.status == .recorded }.count, 2)
        XCTAssertTrue(recorded.transactions.allSatisfy { $0.source == .lifecost && $0.occurredAt == start })
        XCTAssertThrowsError(try useCases.recordSubscriptions(payments, month: Month(date: start)))
        XCTAssertEqual(try store.snapshot(), recorded)
        let suite = "SubscriptionTags-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = KakeiboViewModel(store: store, preferences: DevicePreferences(defaults: defaults),
                                    reminderService: FakeReminders())
        for transaction in recorded.transactions {
            XCTAssertEqual(model.managementTag(for: transaction), "管理・サブスク：" + transaction.memo)
        }
        let manual = Transaction(type: .expense, amount: 1, categoryId: category.id, occurredAt: start)
        XCTAssertNil(model.managementTag(for: manual))

    }

    @MainActor func testAutomaticSubscriptionsOnlyRecordDueFixedCurrentMonthAndBackupSetting() throws {
        let store = try store()
        let useCases = FinanceUseCases(repository: store)
        let start = date(2026, 9, 1)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        for (name, day, variable, enabled) in [("定額", 1, false, true), ("将来", 30, false, true),
                                               ("変動", 1, true, true), ("手動", 1, false, false)] {
            let due = date(2026, 9, day)
            var contract = FinanceContract(name: name, kind: .subscription,
                categoryId: category.id, expectedAmount: 1_000, isVariable: variable,
                startDate: start, firstDueDate: due)
            contract.automaticallyRecordPayment = enabled
            try useCases.saveContract(contract, effectiveFrom: start)
        }
        try useCases.recordAutomaticSubscriptions(now: date(2026, 10, 15))
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.transactions.count, 1)
        XCTAssertEqual(snapshot.transactions.first?.memo, "定額")
        XCTAssertEqual(snapshot.transactions.first?.occurredAt, date(2026, 10, 1))
        try useCases.recordAutomaticSubscriptions(now: date(2026, 10, 15))
        XCTAssertEqual(try store.snapshot(), snapshot)
        let data = try JSONEncoder().encode(snapshot.finance)
        XCTAssertEqual(try JSONDecoder().decode(FinanceState.self, from: data), snapshot.finance)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var contracts = try XCTUnwrap(json["contracts"] as? [[String: Any]])
        for index in contracts.indices { contracts[index].removeValue(forKey: "automaticallyRecordPayment") }
        json["contracts"] = contracts
        let old = try JSONDecoder().decode(FinanceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.contracts.allSatisfy { $0.automaticallyRecordPayment == nil })
    }

    @MainActor func testCardPurchaseSettlementRefundAndBackupRoundTrip() throws {
        let store = try store()
        let useCases = FinanceUseCases(repository: store)
        let start = date(2026, 10, 1)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start,
            openingBalance: 100_000)
        let card = FinanceAccount(name: "カード", kind: .creditCard, openingDate: start,
            openingBalance: 0)
        try useCases.saveAccount(bank); try useCases.saveAccount(card)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        let purchase = Transaction(type: .expense, amount: 12_000,
            categoryId: category.id, occurredAt: start)
        try useCases.recordManual(purchase, accountId: card.id)
        let afterPurchase = try store.snapshot()
        XCTAssertEqual(try FinanceRules.accountBalance(card,
            postings: afterPurchase.finance.postings, asOf: start), 12_000)
        XCTAssertEqual(try FinanceRules.accountBalance(bank,
            postings: afterPurchase.finance.postings, asOf: start), 100_000)
        try useCases.refund(originalTransactionId: purchase.id, amount: 2_000,
            date: start, accountId: card.id)
        try useCases.settleCard(amount: 10_000, cardId: card.id, bankId: bank.id,
            date: start)
        let result = try store.snapshot()
        XCTAssertEqual(try FinanceRules.accountBalance(card,
            postings: result.finance.postings, asOf: start), 0)
        XCTAssertEqual(try FinanceRules.accountBalance(bank,
            postings: result.finance.postings, asOf: start), 90_000)
        let summary = try MonthlySummary.calculate(result.transactions,
            in: Month(date: start).range, refunds: result.finance.refunds)
        XCTAssertEqual(summary.expense, 10_000)
        XCTAssertEqual(summary.income, 0)
        XCTAssertEqual(try BackupFormat.decode(BackupFormat.encode(result)).finance,
                       result.finance)
    }

    @MainActor func testPlannedPaymentIsNotExpenseAndRecordIsAtomicOnce() throws {
        let store = try store()
        let useCases = FinanceUseCases(repository: store)
        let due = date(2026, 10, 1)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: due,
            openingBalance: 50_000)
        try useCases.saveAccount(bank)
        let contract = FinanceContract(name: "通信", kind: .subscription,
            categoryId: category.id, expectedAmount: 3_000,
            startDate: due, firstDueDate: due, paymentAccountId: bank.id)
        try useCases.saveContract(contract, effectiveFrom: due)
        let before = try store.snapshot()
        XCTAssertTrue(before.transactions.isEmpty)
        let payment = try XCTUnwrap(before.finance.payments.first)
        let failing = FinanceUseCases(repository: Store(container: store.container,
            beforeSave: { throw StoreError.conflict }))
        XCTAssertThrowsError(try failing.recordPayment(payment, amount: 3_200,
            categoryId: category.id, date: due, accountId: bank.id))
        XCTAssertEqual(try store.snapshot(), before)
        try useCases.recordPayment(payment, amount: 3_200,
            categoryId: category.id, date: due, accountId: bank.id)
        XCTAssertThrowsError(try useCases.recordPayment(payment, amount: 3_200,
            categoryId: category.id, date: due, accountId: bank.id))
        let after = try store.snapshot()
        XCTAssertEqual(after.transactions.count, 1)
        XCTAssertEqual(after.finance.payments.first?.status, .recorded)
        XCTAssertEqual(try FinanceRules.effectiveMonth(after.finance,
            month: Month(date: due)).contracts, 3_200)
        XCTAssertEqual(try FinanceRules.accountBalance(bank,
            postings: after.finance.postings, asOf: due), 46_800)
        XCTAssertThrowsError(try store.delete(id: try XCTUnwrap(after.finance.payments.first?.transactionId)))
        XCTAssertEqual(try store.snapshot(), after)
    }

    @MainActor func testScheduleExtendsAfterInitialHorizonWithoutDuplicateOccurrences() throws {
        let store = try store()
        let useCases = FinanceUseCases(repository: store)
        let start = date(2026, 1, 1)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        try useCases.saveContract(FinanceContract(name: "家賃", kind: .fixedCost,
            categoryId: category.id, expectedAmount: 70_000,
            startDate: start, firstDueDate: start), effectiveFrom: start)
        let first = try store.snapshot().finance.payments
        try useCases.ensurePayments(through: date(2028, 1, 1))
        let extended = try store.snapshot().finance.payments
        XCTAssertTrue(extended.count > first.count)
        XCTAssertTrue(Set(first.map(\.id)).isSubset(of: Set(extended.map(\.id))))
        try useCases.ensurePayments(through: date(2028, 1, 1))
        XCTAssertEqual(try store.snapshot().finance.payments, extended)
    }

    @MainActor func testV3StoreMigratesToV4WithoutLosingTransactions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let category = PersonalKakeiboDomain.Category(name: "食費", type: .expense)
        let transaction = Transaction(type: .expense, amount: 500,
            categoryId: category.id, occurredAt: date(2026, 10, 1))
        do {
            let schema = Schema(versionedSchema: KakeiboSchemaV3.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(StoredCategory(category))
            context.insert(StoredTransaction(transaction))
            try context.save()
        }
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let migrated = Store(container: try ModelContainer(for: schema,
                migrationPlan: KakeiboMigrationPlan.self, configurations: config))
            XCTAssertEqual(try migrated.allTransactions(), [transaction])
            XCTAssertEqual(try migrated.snapshot().finance, FinanceState())
            try FinanceUseCases(repository: migrated).saveAccount(
                FinanceAccount(name: "現金", kind: .cash,
                    openingDate: date(2026, 10, 1), openingBalance: 1_000))
        }
        let reopened = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        XCTAssertEqual(try reopened.allTransactions(), [transaction])
        XCTAssertEqual(try reopened.snapshot().finance.accounts.count, 1)
    }
}
