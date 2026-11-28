import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class BonusBackupTests: XCTestCase {
    private let start = Month.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!

    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let value = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        try value.seed()
        return value
    }

    private func planFinance(categoryId: UUID, bonus: Bool) throws -> FinanceState {
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 500_000)
        let loan = FinanceAccount(name: "未払", kind: .loan, openingDate: start, openingBalance: 0)
        var contract = FinanceContract(name: "冷蔵庫", kind: .installment, categoryId: categoryId,
            expectedAmount: 5_833, startDate: start, firstDueDate: start,
            paymentAccountId: bank.id, liabilityAccountId: loan.id,
            maximumCycles: 12, principal: 100_000, totalPayment: 110_000)
        let dates = try (0..<12).map { try contract.interval.date(from: start, index: $0) }
        let schedule: [InstallmentPayment]
        if bonus {
            contract.bonusMonths = [6, 12]; contract.bonusAmount = 20_000
            schedule = try BonusSchedule.make(principal: 100_000, total: 110_000, dueDates: dates,
                                              bonusMonths: [6, 12], bonusAmount: 20_000)
        } else {
            schedule = try InstallmentSchedule.make(principal: 100_000, total: 110_000, cycles: 12)
        }
        var payments: [ScheduledPayment] = []
        for (index, item) in schedule.enumerated() {
            payments.append(ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
                cycleIndex: index, dueDate: dates[index], coverageStart: dates[index],
                expectedAmount: item.amount, plannedPrincipal: item.principal,
                plannedInterest: item.interest))
        }
        let purchase = AccountPosting(accountId: loan.id, eventId: contract.id,
            kind: .installmentPurchase, date: start, amount: 100_000)
        return FinanceState(accounts: [bank, loan], postings: [purchase], contracts: [contract], payments: payments)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reencoded(_ object: [String: Any], version: Int) throws -> Data {
        var copy = object
        copy["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: copy)
    }

    @MainActor func testBonusPlanRoundTripsThroughV6() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        var next = try source.snapshot()
        next.finance = try planFinance(categoryId: category.id, bonus: true)
        try source.apply(next, expecting: try source.snapshot())
        let original = try source.snapshot()

        let data = try BackupFormat.encode(original)
        XCTAssertEqual(try jsonObject(data)["schemaVersion"] as? Int, 6)
        let decoded = try BackupFormat.decode(data)
        XCTAssertEqual(decoded.finance, original.finance)

        let destination = try store()
        let preview = try BackupFormat.preview(decoded, current: destination.snapshot(), overwrite: false)
        try destination.apply(preview.merged, expecting: preview.original)
        let restored = try destination.snapshot().finance
        XCTAssertEqual(restored, original.finance)
        XCTAssertEqual(restored.contracts[0].bonusMonths, [6, 12])
        XCTAssertEqual(restored.contracts[0].bonusAmount, 20_000)
    }

    @MainActor func testV5BackupWithAPlainPlanStillLoadsButCannotCarryBonusPlans() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        var plain = try source.snapshot()
        plain.finance = try planFinance(categoryId: category.id, bonus: false)
        let plainObject = try jsonObject(BackupFormat.encode(plain))
        let v5 = try BackupFormat.decode(reencoded(plainObject, version: 5))
        XCTAssertEqual(v5.finance, plain.finance)

        var bonus = plain
        bonus.finance = try planFinance(categoryId: category.id, bonus: true)
        let bonusObject = try jsonObject(BackupFormat.encode(bonus))
        XCTAssertThrowsError(try BackupFormat.decode(reencoded(bonusObject, version: 5)))
        XCTAssertThrowsError(try BackupFormat.decode(reencoded(bonusObject, version: 4)))
        XCTAssertNoThrow(try BackupFormat.decode(reencoded(bonusObject, version: 6)))
        XCTAssertThrowsError(try BackupFormat.decode(reencoded(bonusObject, version: 7)))
    }

    @MainActor func testInconsistentBonusFieldsAreRejected() throws {
        let source = try store()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        var snapshot = try source.snapshot()
        snapshot.finance = try planFinance(categoryId: category.id, bonus: true)
        let object = try jsonObject(BackupFormat.encode(snapshot))

        func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = object
            var finance = try XCTUnwrap(copy["finance"] as? [String: Any])
            var contracts = try XCTUnwrap(finance["contracts"] as? [[String: Any]])
            change(&contracts[0])
            finance["contracts"] = contracts
            copy["finance"] = finance
            return try JSONSerialization.data(withJSONObject: copy)
        }
        XCTAssertThrowsError(try BackupFormat.decode(mutated { $0["bonusMonths"] = [Int]() }))
        XCTAssertThrowsError(try BackupFormat.decode(mutated { $0["bonusAmount"] = 0 }))
        XCTAssertThrowsError(try BackupFormat.decode(mutated { _ = $0.removeValue(forKey: "bonusAmount") }))

        var broken = snapshot
        broken.finance.contracts[0].bonusMonths = [13]
        XCTAssertThrowsError(try BackupFormat.encode(broken))
    }

    @MainActor func testStoredPlainPlanIsReadUnchangedByTheBonusAwareApp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let category = PersonalKakeiboDomain.Category(name: "家電", type: .expense)
        let finance = try planFinance(categoryId: category.id, bonus: false)
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self,
                                               configurations: config)
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(StoredCategory(category))
            context.insert(try StoredFinanceState(finance))
            try context.save()
        }
        let reopened = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        let read = try reopened.snapshot().finance
        XCTAssertEqual(read, finance)
        XCTAssertFalse(read.usesBonusPlans)
    }
}
