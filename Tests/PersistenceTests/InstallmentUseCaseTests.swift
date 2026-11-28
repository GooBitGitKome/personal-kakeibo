import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class InstallmentUseCaseTests: XCTestCase {
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
                                     cycles: Int = 10,
                                     asset: FinanceUseCases.InstallmentInput.AssetInput? = nil) throws -> UUID {
        try s.useCases.registerInstallment(.init(name: "パソコン", categoryId: s.category.id,
            principal: principal, totalPayment: total, cycles: cycles,
            purchaseDate: date(2026, 11, 1), firstDueDate: date(2026, 11, 1),
            paymentAccountId: s.bank.id, liabilityAccountId: s.loan.id, asset: asset))
    }

    @MainActor private func balance(_ s: Setup, _ account: FinanceAccount) throws -> Int64 {
        try FinanceRules.accountBalance(account, postings: try s.store.snapshot().finance.postings, asOf: far)
    }

    @MainActor private func status(_ s: Setup, _ id: UUID) throws -> InstallmentStatus {
        try XCTUnwrap(try s.store.snapshot().finance.installmentStatus(for: id))
    }

    /// Confirms the next pending payment using the suggested split unless overridden.
    @MainActor private func recordNext(_ s: Setup, _ id: UUID, amount: Int64? = nil, principal: Int64? = nil) throws {
        let finance = try s.store.snapshot().finance
        let payment = try XCTUnwrap(finance.payments.filter { $0.contractId == id && $0.status == .pending }
            .min { $0.dueDate < $1.dueDate })
        let paid = amount ?? payment.expectedAmount
        let split = try XCTUnwrap(try finance.suggestedSplit(for: payment, amount: paid))
        try s.useCases.recordPayment(payment, amount: paid, categoryId: s.category.id,
            date: payment.dueDate, accountId: s.bank.id, principal: principal ?? split.principal)
    }

    @MainActor func testRegistrationCreatesEveryPaymentAndBooksOnlyTheLiability() throws {
        let s = try setup()
        let id = try register(s)
        let snapshot = try s.store.snapshot()
        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertEqual(snapshot.finance.payments.filter { $0.contractId == id }.count, 10)
        XCTAssertEqual(try balance(s, s.loan), 100_000)
        XCTAssertEqual(try balance(s, s.bank), 500_000)
        XCTAssertEqual(try FinanceRules.effectiveMonth(snapshot.finance, month: Month(date: date(2026, 11, 1))).contracts, 1_000)
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 0, remainingCount: 10,
            remainingPayment: 110_000, remainingPrincipal: 100_000))
        try s.useCases.ensurePayments(through: far)
        XCTAssertEqual(try s.store.snapshot().finance.payments.filter { $0.contractId == id }.count, 10)
    }

    @MainActor func testRegistrationCanCreateALinkedAssetAndRejectsInvalidInputAtomically() throws {
        let s = try setup()
        let id = try register(s, asset: .init(usefulMonths: 36))
        let finance = try s.store.snapshot().finance
        let asset = try XCTUnwrap(finance.assets.first)
        XCTAssertEqual(asset.purchasePrice, 100_000)
        XCTAssertEqual(finance.contracts.first { $0.id == id }?.financedAssetId, asset.id)

        let before = try s.store.snapshot()
        XCTAssertThrowsError(try register(s, principal: 100_000, total: 99_999))
        XCTAssertThrowsError(try register(s, cycles: 1))
        XCTAssertThrowsError(try register(s, principal: 0, total: 10, cycles: 2))
        XCTAssertThrowsError(try register(s, cycles: 1_201))
        XCTAssertThrowsError(try register(s, asset: .init(usefulMonths: 0)))
        XCTAssertEqual(try s.store.snapshot(), before)
    }

    @MainActor func testConfirmingPaymentsUsesPlannedSplitAndAllowsActualAmounts() throws {
        let s = try setup()
        let id = try register(s)
        try recordNext(s, id)
        var snapshot = try s.store.snapshot()
        XCTAssertEqual(snapshot.transactions.map(\.amount), [1_000])
        XCTAssertEqual(try balance(s, s.bank), 489_000)
        XCTAssertEqual(try balance(s, s.loan), 90_000)
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 1, remainingCount: 9,
            remainingPayment: 99_000, remainingPrincipal: 90_000))

        try recordNext(s, id, amount: 12_000, principal: 9_000)
        snapshot = try s.store.snapshot()
        XCTAssertEqual(snapshot.transactions.map(\.amount).sorted(), [1_000, 3_000])
        XCTAssertEqual(try status(s, id).remainingPrincipal, 81_000)
    }

    @MainActor func testPrincipalAbovePurchaseAmountAndMismatchedLastPaymentAreRejected() throws {
        let s = try setup()
        let id = try register(s)
        let before = try s.store.snapshot()
        let first = try XCTUnwrap(before.finance.payments.min { $0.dueDate < $1.dueDate })
        XCTAssertThrowsError(try s.useCases.recordPayment(first, amount: 100_001, categoryId: s.category.id,
            date: first.dueDate, accountId: s.bank.id, principal: 100_001))
        XCTAssertEqual(try s.store.snapshot(), before)

        for _ in 0..<9 { try recordNext(s, id) }
        let mid = try s.store.snapshot()
        let last = try XCTUnwrap(mid.finance.payments.first { $0.contractId == id && $0.status == .pending })
        XCTAssertThrowsError(try s.useCases.recordPayment(last, amount: 11_000, categoryId: s.category.id,
            date: last.dueDate, accountId: s.bank.id, principal: 9_999), "last payment must settle all principal")
        XCTAssertEqual(try s.store.snapshot(), mid)
    }

    @MainActor func testPayingEveryCycleEndsThePlanWithOnlyInterestAsExpense() throws {
        let s = try setup()
        let id = try register(s)
        for _ in 0..<10 { try recordNext(s, id) }
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 10, remainingCount: 0,
            remainingPayment: 0, remainingPrincipal: 0))
        XCTAssertEqual(snapshot.finance.contracts.first { $0.id == id }?.status, .ended)
        XCTAssertEqual(snapshot.transactions.reduce(Int64(0)) { $0 + $1.amount }, 10_000)
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 390_000)
    }

    @MainActor func testSkippingAPlanPaymentIsRejected() throws {
        let s = try setup()
        _ = try register(s)
        let payment = try XCTUnwrap(try s.store.snapshot().finance.payments.first)
        let before = try s.store.snapshot()
        XCTAssertThrowsError(try s.useCases.skipPayment(payment))
        XCTAssertEqual(try s.store.snapshot(), before)
    }

    @MainActor func testCancelBeforeAnyPaymentRestoresTheLiability() throws {
        let s = try setup()
        let id = try register(s)
        let before = try s.store.snapshot()
        XCTAssertThrowsError(try s.useCases.cancelInstallment(id, date: date(2026, 11, 2),
            expectedPendingCount: 9, expectedRemainingPrincipal: 100_000), "stale view")
        XCTAssertEqual(try s.store.snapshot(), before)
        try s.useCases.cancelInstallment(id, date: date(2026, 11, 2),
            expectedPendingCount: 10, expectedRemainingPrincipal: 100_000)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 500_000)
        XCTAssertTrue(snapshot.finance.payments.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(snapshot.finance.contracts.first { $0.id == id }?.status, .ended)
        XCTAssertEqual(try FinanceRules.effectiveMonth(snapshot.finance, month: Month(date: date(2026, 11, 1))).contracts, 0)
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 0, remainingCount: 0,
            remainingPayment: 0, remainingPrincipal: 0))
        XCTAssertThrowsError(try s.useCases.cancelInstallment(id, date: date(2026, 11, 3),
            expectedPendingCount: 0, expectedRemainingPrincipal: 0))
    }

    @MainActor func testCancelAfterSomePaymentsKeepsRecordedOnes() throws {
        let s = try setup()
        let id = try register(s)
        for _ in 0..<3 { try recordNext(s, id) }
        let recorded = try s.store.snapshot().finance.payments.filter { $0.status == .recorded }
        try s.useCases.cancelInstallment(id, date: date(2027, 2, 1),
            expectedPendingCount: 7, expectedRemainingPrincipal: 70_000)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(snapshot.finance.payments.filter { $0.status == .recorded }, recorded)
        XCTAssertEqual(snapshot.finance.payments.filter { $0.status == .cancelled }.count, 7)
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 467_000)
        XCTAssertEqual(snapshot.transactions.reduce(Int64(0)) { $0 + $1.amount }, 3_000)
    }

    @MainActor func testPrepaymentPaysRemainingPrincipalAndFeeOnly() throws {
        let s = try setup()
        let id = try register(s)
        for _ in 0..<4 { try recordNext(s, id) }
        try s.useCases.prepayInstallment(id, date: date(2027, 3, 1), fee: 500,
            expectedPendingCount: 6, expectedRemainingPrincipal: 60_000)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try balance(s, s.bank), 500_000 - 44_000 - 60_500)
        XCTAssertEqual(snapshot.transactions.reduce(Int64(0)) { $0 + $1.amount }, 4_000 + 500)
        XCTAssertEqual(snapshot.finance.payments.filter { $0.status == .cancelled }.count, 6)
        XCTAssertEqual(snapshot.finance.contracts.first { $0.id == id }?.status, .ended)
        XCTAssertEqual(try status(s, id).remainingPrincipal, 0)
        XCTAssertThrowsError(try s.useCases.prepayInstallment(id, date: date(2027, 3, 2), fee: 0,
            expectedPendingCount: 0, expectedRemainingPrincipal: 0))
    }

    @MainActor func testPrepaymentWithoutFeeAddsNoExpense() throws {
        let s = try setup()
        let id = try register(s)
        try s.useCases.prepayInstallment(id, date: date(2026, 12, 1), fee: 0,
            expectedPendingCount: 10, expectedRemainingPrincipal: 100_000)
        let snapshot = try s.store.snapshot()
        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertEqual(try balance(s, s.bank), 400_000)
        XCTAssertEqual(try balance(s, s.loan), 0)
    }

    @MainActor func testChangingTermsRebuildsOnlyPendingPayments() throws {
        let s = try setup()
        let id = try register(s)
        for _ in 0..<3 { try recordNext(s, id) }
        let recorded = try s.store.snapshot().finance.payments.filter { $0.status == .recorded }
        let before = try s.store.snapshot()
        XCTAssertThrowsError(try s.useCases.changeInstallmentTerms(id, remainingTotal: 69_999, remainingCycles: 5,
            expectedPendingCount: 7, expectedRemainingPrincipal: 70_000), "total below remaining principal")
        XCTAssertEqual(try s.store.snapshot(), before)

        try s.useCases.changeInstallmentTerms(id, remainingTotal: 76_999, remainingCycles: 5,
            expectedPendingCount: 7, expectedRemainingPrincipal: 70_000)
        let snapshot = try s.store.snapshot()
        XCTAssertEqual(snapshot.finance.payments.filter { $0.status == .recorded }, recorded)
        let pending = snapshot.finance.payments.filter { $0.contractId == id && $0.status == .pending }
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(pending.reduce(Int64(0)) { $0 + $1.expectedAmount }, 76_999)
        XCTAssertEqual(pending.reduce(Int64(0)) { $0 + ($1.plannedPrincipal ?? 0) }, 70_000)
        XCTAssertEqual(snapshot.finance.payments.filter { $0.status == .cancelled }.count, 7)
        XCTAssertEqual(try status(s, id), InstallmentStatus(paidCount: 3, remainingCount: 5,
            remainingPayment: 76_999, remainingPrincipal: 70_000))
        try s.useCases.ensurePayments(through: far)
        XCTAssertEqual(try s.store.snapshot().finance.payments, snapshot.finance.payments)
        for _ in 0..<5 { try recordNext(s, id) }
        XCTAssertEqual(try balance(s, s.loan), 0)
        XCTAssertEqual(try s.store.snapshot().finance.contracts.first { $0.id == id }?.status, .ended)
    }

    @MainActor func testPlanSurvivesBackupRoundTripAfterActivity() throws {
        let s = try setup()
        let id = try register(s)
        for _ in 0..<2 { try recordNext(s, id) }
        try s.useCases.changeInstallmentTerms(id, remainingTotal: 90_000, remainingCycles: 4,
            expectedPendingCount: 8, expectedRemainingPrincipal: 80_000)
        let original = try s.store.snapshot()
        let decoded = try BackupFormat.decode(BackupFormat.encode(original))
        XCTAssertEqual(decoded.finance, original.finance)
        XCTAssertEqual(try decoded.finance.installmentStatus(for: id), try original.finance.installmentStatus(for: id))
    }
}
