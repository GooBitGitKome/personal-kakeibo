import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class InstallmentRulesTests: XCTestCase {
    private let start = Month.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!

    private struct Fixture {
        var state: FinanceState
        var categories: [Category]
        var contract: FinanceContract
        var bank: FinanceAccount
        var loan: FinanceAccount
    }

    private func fixture(principal: Int64 = 100_000, total: Int64 = 110_000, cycles: Int = 10) throws -> Fixture {
        let category = Category(name: "分割", type: .expense)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 500_000)
        let loan = FinanceAccount(name: "未払", kind: .loan, openingDate: start, openingBalance: 0)
        let schedule = try InstallmentSchedule.make(principal: principal, total: total, cycles: cycles)
        let contract = FinanceContract(name: "パソコン", kind: .installment, categoryId: category.id,
            expectedAmount: schedule[0].amount, startDate: start, firstDueDate: start,
            paymentAccountId: bank.id, liabilityAccountId: loan.id,
            maximumCycles: cycles, principal: principal, totalPayment: total)
        var payments: [ScheduledPayment] = []
        for (index, item) in schedule.enumerated() {
            let due = try contract.interval.date(from: start, index: index)
            payments.append(ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
                cycleIndex: index, dueDate: due, coverageStart: due, expectedAmount: item.amount,
                plannedPrincipal: item.principal, plannedInterest: item.interest))
        }
        let purchase = AccountPosting(accountId: loan.id, eventId: contract.id,
            kind: .installmentPurchase, date: start, amount: principal)
        let state = FinanceState(accounts: [bank, loan], postings: [purchase],
            contracts: [contract], payments: payments)
        return Fixture(state: state, categories: [category], contract: contract, bank: bank, loan: loan)
    }

    private func validate(_ fixture: Fixture) throws {
        try FinanceRules.validate(fixture.state, categories: fixture.categories, transactions: [])
    }

    func testRegisteredPlanIsValid() throws {
        try validate(try fixture())
    }

    func testLegacyDataWithoutPlanFieldsDecodesUnchanged() throws {
        let category = UUID()
        let contract = FinanceContract(name: "端末分割", kind: .installment, categoryId: category,
            expectedAmount: 10_000, startDate: start, firstDueDate: start, maximumCycles: 12)
        let payment = ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
            cycleIndex: 0, dueDate: start, coverageStart: start, expectedAmount: 10_000)
        let state = FinanceState(contracts: [contract], payments: [payment])
        let data = try JSONEncoder().encode(state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("totalPayment"))
        XCTAssertFalse(text.contains("plannedPrincipal"))
        let decoded = try JSONDecoder().decode(FinanceState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertFalse(decoded.usesInstallmentPlans)
    }

    func testPlanStateReportsItUsesInstallmentPlans() throws {
        XCTAssertTrue(try fixture().state.usesInstallmentPlans)
    }

    func testRejectsInvalidPlanContracts() throws {
        var f = try fixture()
        f.state.contracts[0].totalPayment = 99_999
        XCTAssertThrowsError(try validate(f), "total below principal")

        f = try fixture()
        f.state.contracts[0].totalPayment = 9
        f.state.contracts[0].principal = 5
        XCTAssertThrowsError(try validate(f), "total below cycles")

        f = try fixture()
        f.state.contracts[0].liabilityAccountId = f.bank.id
        XCTAssertThrowsError(try validate(f), "liability account must be a liability")

        f = try fixture()
        f.state.contracts[0].paymentAccountId = f.loan.id
        XCTAssertThrowsError(try validate(f), "payer must be a bank or cash account")

        f = try fixture()
        f.state.contracts[0].kind = .subscription
        XCTAssertThrowsError(try validate(f), "plans are installment contracts")
    }

    func testRejectsMissingOrWrongPurchasePosting() throws {
        var f = try fixture()
        f.state.postings = []
        XCTAssertThrowsError(try validate(f))

        f = try fixture()
        f.state.postings[0].amount = 99_999
        XCTAssertThrowsError(try validate(f))

        f = try fixture()
        f.state.postings.append(f.state.postings[0].withNewID())
        XCTAssertThrowsError(try validate(f), "exactly one purchase posting")
    }

    func testRejectsPendingPaymentsWithoutConsistentPlannedSplit() throws {
        var f = try fixture()
        f.state.payments[0].plannedPrincipal = nil
        XCTAssertThrowsError(try validate(f))

        f = try fixture()
        f.state.payments[0].plannedInterest = (f.state.payments[0].plannedInterest ?? 0) + 1
        XCTAssertThrowsError(try validate(f))
    }

    func testRejectsRecordedPrincipalAbovePurchaseAmount() throws {
        var f = try fixture()
        let event = UUID()
        f.state.postings.append(.init(accountId: f.bank.id, eventId: event, kind: .loanSettlement,
            date: start, amount: -150_000))
        f.state.payments[0].status = .recorded
        f.state.payments[0].settlementEventId = event
        f.state.payments[0].principalAmount = 100_001
        f.state.payments[0].interestAmount = 0
        f.state.payments[0].actualAmount = 100_001
        XCTAssertThrowsError(try validate(f))
    }

    func testGeneratePaymentsLeavesPlanPaymentsUntouched() throws {
        let f = try fixture()
        let far = Month.calendar.date(from: DateComponents(year: 2040, month: 1, day: 1))!
        let generated = try FinanceRules.generatePayments(f.state, through: far)
        XCTAssertEqual(generated, f.state)
    }

    func testEffectiveCostUsesPlannedThenActualInterestAndSkipsCancelled() throws {
        var f = try fixture()
        let first = Month(date: start)
        XCTAssertEqual(try FinanceRules.effectiveMonth(f.state, month: first).contracts, 1_000)

        f.state.payments[0].status = .recorded
        f.state.payments[0].actualAmount = 11_500
        f.state.payments[0].principalAmount = 10_000
        f.state.payments[0].interestAmount = 1_500
        f.state.payments[0].settlementEventId = UUID()
        XCTAssertEqual(try FinanceRules.effectiveMonth(f.state, month: first).contracts, 1_500)

        let second = Month(date: try f.contract.interval.date(from: start, index: 1))
        XCTAssertEqual(try FinanceRules.effectiveMonth(f.state, month: second).contracts, 1_000)
        f.state.payments[1].status = .cancelled
        XCTAssertEqual(try FinanceRules.effectiveMonth(f.state, month: second).contracts, 0)
    }
}

private extension AccountPosting {
    func withNewID() -> AccountPosting {
        AccountPosting(accountId: accountId, eventId: eventId, kind: kind, date: date, amount: amount)
    }
}
