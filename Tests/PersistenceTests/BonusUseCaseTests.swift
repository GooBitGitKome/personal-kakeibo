import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class BonusUseCaseTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    private let far = Month.calendar.date(from: DateComponents(year: 2035, month: 1, day: 1))!

    private struct Setup {
        let store: Store
        let useCases: FinanceUseCases
        let bank: FinanceAccount
        let loan: FinanceAccount
        let category: PersonalKakeiboDomain.Category
    }

    @MainActor private func setup() throws -> Setup {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let store = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        try store.seed()
        let useCases = FinanceUseCases(repository: store)
        let start = date(2026, 11, 1)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 500_000)
        let loan = FinanceAccount(name: "未払", kind: .loan, openingDate: start, openingBalance: 0)
        try useCases.saveAccount(bank); try useCases.saveAccount(loan)
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        return Setup(store: store, useCases: useCases, bank: bank, loan: loan, category: category)
    }

    @MainActor private func register(_ s: Setup, principal: Int64 = 100_000, total: Int64 = 110_000,
                                     cycles: Int = 12, firstDue: Date? = nil,
                                     bonus: FinanceUseCases.InstallmentInput.BonusInput?) throws -> UUID {
        try s.useCases.registerInstallment(.init(name: "冷蔵庫", categoryId: s.category.id,
            principal: principal, totalPayment: total, cycles: cycles,
            purchaseDate: date(2026, 11, 1), firstDueDate: firstDue ?? date(2026, 11, 1),
            paymentAccountId: s.bank.id, liabilityAccountId: s.loan.id, bonus: bonus))
    }

    private let juneAndDecember = FinanceUseCases.InstallmentInput.BonusInput(months: [12, 6], amount: 20_000)

    @MainActor private func balance(_ s: Setup, _ account: FinanceAccount) throws -> Int64 {
        try FinanceRules.accountBalance(account, postings: try s.store.snapshot().finance.postings, asOf: far)
    }

    @MainActor private func status(_ s: Setup, _ id: UUID) throws -> InstallmentStatus {
        try XCTUnwrap(try s.store.snapshot().finance.installmentStatus(for: id))
    }

    @MainActor private func payments(_ s: Setup, _ id: UUID) throws -> [ScheduledPayment] {
        try s.store.snapshot().finance.payments.filter { $0.contractId == id }.sorted { $0.dueDate < $1.dueDate }
    }

    @MainActor private func recordNext(_ s: Setup, _ id: UUID) throws {
        let finance = try s.store.snapshot().finance
        let payment = try XCTUnwrap(finance.payments.filter { $0.contractId == id && $0.status == .pending }
            .min { $0.dueDate < $1.dueDate })
        let split = try XCTUnwrap(try finance.suggestedSplit(for: payment, amount: payment.expectedAmount))
        try s.useCases.recordPayment(payment, amount: payment.expectedAmount, categoryId: s.category.id,
            date: payment.dueDate, accountId: s.bank.id, principal: split.principal)
    }

    @MainActor func testRegistrationBuildsTheBonusScheduleAndBooksOnlyTheLiability() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        let snapshot = try s.store.snapshot()
        let contract = try XCTUnwrap(snapshot.finance.contracts.first { $0.id == id })
        XCTAssertEqual(contract.bonusMonths, [6, 12])
        XCTAssertEqual(contract.bonusAmount, 20_000)

        var expected = [Int64](repeating: 5_833, count: 12)
        expected[1] = 25_833
        expected[7] = 25_833
        expected[11] = 5_837
        let list = try payments(s, id)
        XCTAssertEqual(list.map(\.expectedAmount), expected)
        XCTAssertEqual(list[1].dueDate, date(2026, 12, 1))
        XCTAssertEqual(list[7].dueDate, date(2027, 6, 1))

        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertEqual(try balance(s, s.loan), 100_000)
        XCTAssertEqual(try balance(s, s.bank), 500_000)
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 0, remainingCount: 12,
            remainingPayment: 110_000, remainingPrincipal: 100_000))
        let december = try FinanceRules.effectiveMonth(snapshot.finance, month: Month(date: date(2026, 12, 1)))
        XCTAssertEqual(december.contracts, list[1].plannedInterest)
        try s.useCases.ensurePayments(through: far)
        XCTAssertEqual(try payments(s, id), list)
    }

    @MainActor func testInvalidBonusInputSavesNothing() throws {
        let s = try setup()
        let before = try s.store.snapshot()
        func bonus(_ months: Set<Int>, _ amount: Int64) -> FinanceUseCases.InstallmentInput.BonusInput {
            .init(months: months, amount: amount)
        }
        XCTAssertThrowsError(try register(s, bonus: bonus([6, 12], 0)))
        XCTAssertThrowsError(try register(s, bonus: bonus([], 20_000)))
        XCTAssertThrowsError(try register(s, bonus: bonus([13], 20_000)))
        XCTAssertThrowsError(try register(s, bonus: bonus([0, 6], 20_000)))
        // no bonus month inside a 3-payment period (November to January)
        XCTAssertThrowsError(try register(s, cycles: 3, bonus: bonus([6], 1_000)))
        // the monthly part would be smaller than the number of payments
        XCTAssertThrowsError(try register(s, principal: 40_000, total: 50_000, bonus: bonus([6, 12], 24_999)))
        XCTAssertEqual(try s.store.snapshot(), before)
    }

    @MainActor func testExistingInstallmentIsUntouchedByRegisteringABonusPlan() throws {
        let s = try setup()
        let plain = try register(s, bonus: nil)
        let before = try s.store.snapshot()
        let plainPayments = try payments(s, plain)
        let plainStatus = try status(s, plain)
        _ = try register(s, bonus: juneAndDecember)
        let after = try s.store.snapshot()
        XCTAssertEqual(try payments(s, plain), plainPayments)
        XCTAssertEqual(try status(s, plain), plainStatus)
        XCTAssertEqual(after.finance.contracts.first { $0.id == plain },
                       before.finance.contracts.first { $0.id == plain })
        XCTAssertNil(after.finance.contracts.first { $0.id == plain }?.bonusAmount)
    }

    @MainActor func testPayingEveryPaymentIncludingBonusMonthsEndsThePlan() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        try recordNext(s, id)
        try recordNext(s, id)   // 2026-12, a bonus month
        let december = try payments(s, id)[1]
        XCTAssertEqual(december.status, .recorded)
        XCTAssertEqual(december.actualAmount, 25_833)
        XCTAssertEqual(try balance(s, s.bank), 500_000 - 5_833 - 25_833)
        let afterTwo = try s.store.snapshot()
        XCTAssertEqual(afterTwo.transactions.map(\.amount).reduce(0, +),
                       try payments(s, id).prefix(2).reduce(Int64(0)) { $0 + ($1.plannedInterest ?? 0) })
        for _ in 0..<10 { try recordNext(s, id) }
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 12, remainingCount: 0,
            remainingPayment: 0, remainingPrincipal: 0))
        let done = try s.store.snapshot()
        XCTAssertEqual(done.finance.contracts.first { $0.id == id }?.status, .ended)
        XCTAssertEqual(done.transactions.reduce(Int64(0)) { $0 + $1.amount }, 10_000)
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 390_000)
    }

    @MainActor func testCancelAfterABonusMonthKeepsRecordedPayments() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        for _ in 0..<3 { try recordNext(s, id) }
        let recorded = try payments(s, id).filter { $0.status == .recorded }
        let current = try status(s, id)
        try s.useCases.cancelInstallment(id, date: date(2027, 2, 1),
            expectedPendingCount: current.remainingCount, expectedRemainingPrincipal: current.remainingPrincipal)
        XCTAssertEqual(try payments(s, id).filter { $0.status == .recorded }, recorded)
        XCTAssertEqual(try payments(s, id).filter { $0.status == .cancelled }.count, 9)
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try s.store.snapshot().finance.contracts.first { $0.id == id }?.status, .ended)
    }

    @MainActor func testPrepaymentOfABonusPlan() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        for _ in 0..<2 { try recordNext(s, id) }
        let current = try status(s, id)
        try s.useCases.prepayInstallment(id, date: date(2027, 1, 15), fee: 0,
            expectedPendingCount: current.remainingCount, expectedRemainingPrincipal: current.remainingPrincipal)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 500_000 - 5_833 - 25_833 - current.remainingPrincipal)
        XCTAssertEqual(snapshot.transactions.count, 2)
        XCTAssertEqual(snapshot.finance.contracts.first { $0.id == id }?.status, .ended)
    }

    @MainActor func testPrepaymentWithAFeeBooksOnlyTheFeeAsAnExpense() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        let current = try status(s, id)
        try s.useCases.prepayInstallment(id, date: date(2026, 11, 20), fee: 500,
            expectedPendingCount: current.remainingCount, expectedRemainingPrincipal: current.remainingPrincipal)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(snapshot.transactions.map(\.amount), [500])
        XCTAssertEqual(try balance(s, s.bank), 500_000 - 100_500)
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try payments(s, id).filter { $0.status == .cancelled }.count, 12)
    }

    @MainActor func testChangingTermsOfABonusPlanIsRejectedWithoutChanges() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        try recordNext(s, id)
        let before = try s.store.snapshot()
        let current = try status(s, id)
        XCTAssertThrowsError(try s.useCases.changeInstallmentTerms(id,
            remainingTotal: current.remainingPayment, remainingCycles: current.remainingCount,
            expectedPendingCount: current.remainingCount, expectedRemainingPrincipal: current.remainingPrincipal))
        XCTAssertEqual(try s.store.snapshot(), before)
    }

    @MainActor func testBonusFieldsCannotBeEditedThroughTheGenericContractEditor() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        let before = try s.store.snapshot()
        var changed = try XCTUnwrap(before.finance.contracts.first { $0.id == id })
        changed.bonusAmount = 1
        XCTAssertThrowsError(try s.useCases.saveContract(changed))
        changed = try XCTUnwrap(before.finance.contracts.first { $0.id == id })
        changed.bonusMonths = nil
        XCTAssertThrowsError(try s.useCases.saveContract(changed))
        XCTAssertEqual(try s.store.snapshot(), before)
    }

    @MainActor func testBonusPlanSurvivesBackupAfterActivity() throws {
        let s = try setup()
        let id = try register(s, bonus: juneAndDecember)
        for _ in 0..<3 { try recordNext(s, id) }
        let original = try s.store.snapshot()
        let decoded = try BackupFormat.decode(BackupFormat.encode(original))
        XCTAssertEqual(decoded.finance, original.finance)
        XCTAssertEqual(try decoded.finance.installmentStatus(for: id), try original.finance.installmentStatus(for: id))
    }
}
