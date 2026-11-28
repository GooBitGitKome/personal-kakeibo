import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class InstallmentBackupTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let value = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        try value.seed()
        return value
    }

    /// A registered 10-cycle plan, built directly so these tests do not depend on the use cases.
    private func planFinance(categoryId: UUID) throws -> FinanceState {
        let start = date(2026, 11, 1)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 500_000)
        let loan = FinanceAccount(name: "未払", kind: .loan, openingDate: start, openingBalance: 0)
        let schedule = try InstallmentSchedule.make(principal: 100_000, total: 110_000, cycles: 10)
        let contract = FinanceContract(name: "パソコン", kind: .installment, categoryId: categoryId,
            expectedAmount: schedule[0].amount, startDate: start, firstDueDate: start,
            paymentAccountId: bank.id, liabilityAccountId: loan.id,
            maximumCycles: 10, principal: 100_000, totalPayment: 110_000)
        var payments: [ScheduledPayment] = []
        for (index, item) in schedule.enumerated() {
            let due = try contract.interval.date(from: start, index: index)
            payments.append(ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
                cycleIndex: index, dueDate: due, coverageStart: due, expectedAmount: item.amount,
                plannedPrincipal: item.principal, plannedInterest: item.interest))
        }
        let purchase = AccountPosting(accountId: loan.id, eventId: contract.id,
            kind: .installmentPurchase, date: start, amount: 100_000)
        return FinanceState(accounts: [bank, loan], postings: [purchase], contracts: [contract], payments: payments)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func testBackupIsCurrentVersionAndInstallmentPlanRoundTrips() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        var next = try source.snapshot()
        next.finance = try planFinance(categoryId: category.id)
        try source.apply(next, expecting: try source.snapshot())
        let original = try source.snapshot()

        let data = try BackupFormat.encode(original)
        XCTAssertEqual(try jsonObject(data)["schemaVersion"] as? Int, 6)
        let decoded = try BackupFormat.decode(data)
        XCTAssertEqual(decoded.finance, original.finance)

        let destination = try store()
        let preview = try BackupFormat.preview(decoded, current: destination.snapshot(), overwrite: false)
        try destination.apply(preview.merged, expecting: preview.original)
        XCTAssertEqual(try destination.snapshot().finance, original.finance)
    }

    @MainActor func testOlderBackupVersionsStillLoadAndCannotCarryPlans() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        // A v4 file without plan data is read exactly as before.
        let plain = try source.snapshot()
        var object = try jsonObject(BackupFormat.encode(plain))
        object["schemaVersion"] = 4
        let v4 = try BackupFormat.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(BackupFormat.equivalent(v4, plain))
        // Plan data is only valid from v5.
        var withPlan = plain
        withPlan.finance = try planFinance(categoryId: category.id)
        var planObject = try jsonObject(BackupFormat.encode(withPlan))
        planObject["schemaVersion"] = 4
        XCTAssertThrowsError(try BackupFormat.decode(JSONSerialization.data(withJSONObject: planObject)))
    }

    @MainActor func testInconsistentPlanIsRejectedOnEncodeAndDecode() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        var snapshot = try source.snapshot()
        snapshot.finance = try planFinance(categoryId: category.id)
        var object = try jsonObject(BackupFormat.encode(snapshot))
        var finance = try XCTUnwrap(object["finance"] as? [String: Any])
        var contracts = try XCTUnwrap(finance["contracts"] as? [[String: Any]])
        contracts[0]["principal"] = 100_001
        finance["contracts"] = contracts
        object["finance"] = finance
        XCTAssertThrowsError(try BackupFormat.decode(JSONSerialization.data(withJSONObject: object)))

        var broken = snapshot
        broken.finance.contracts[0].totalPayment = 99_999
        XCTAssertThrowsError(try BackupFormat.encode(broken))
    }

    @MainActor func testV4StoreWithLegacyInstallmentOpensUnchanged() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let start = date(2026, 10, 1)
        let category = PersonalKakeiboDomain.Category(name: "家電", type: .expense)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 100_000)
        let loan = FinanceAccount(name: "借入", kind: .loan, openingDate: start, openingBalance: 60_000)
        let contract = FinanceContract(name: "端末分割", kind: .installment, categoryId: category.id,
            expectedAmount: 10_000, startDate: start, firstDueDate: start,
            paymentAccountId: bank.id, liabilityAccountId: loan.id, maximumCycles: 6, principal: 60_000)
        let payment = ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
            cycleIndex: 0, dueDate: start, coverageStart: start, expectedAmount: 10_000)
        let legacy = FinanceState(accounts: [bank, loan], contracts: [contract], payments: [payment])
        do {
            let schema = Schema(versionedSchema: KakeiboSchemaV4.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(StoredCategory(category))
            context.insert(try StoredFinanceState(legacy))
            try context.save()
        }
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let opened = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        let finance = try opened.snapshot().finance
        XCTAssertEqual(finance, legacy)
        XCTAssertFalse(finance.usesInstallmentPlans)
    }
}
