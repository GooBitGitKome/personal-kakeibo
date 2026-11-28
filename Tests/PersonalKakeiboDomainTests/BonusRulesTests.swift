import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class BonusRulesTests: XCTestCase {
    private let start = Month.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!

    private struct Fixture {
        var state: FinanceState
        var categories: [PersonalKakeiboDomain.Category]
    }

    private func fixture(bonus: Bool = true) throws -> Fixture {
        let category = PersonalKakeiboDomain.Category(name: "分割", type: .expense)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: start, openingBalance: 500_000)
        let loan = FinanceAccount(name: "未払", kind: .loan, openingDate: start, openingBalance: 0)
        var contract = FinanceContract(name: "冷蔵庫", kind: .installment, categoryId: category.id,
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
        return Fixture(state: FinanceState(accounts: [bank, loan], postings: [purchase],
            contracts: [contract], payments: payments), categories: [category])
    }

    private func validate(_ fixture: Fixture) throws {
        try FinanceRules.validate(fixture.state, categories: fixture.categories, transactions: [])
    }

    func testBonusPlanIsValidAndReported() throws {
        let f = try fixture()
        try validate(f)
        XCTAssertTrue(f.state.usesBonusPlans)
        XCTAssertTrue(f.state.usesInstallmentPlans)
    }

    func testPlanWithoutBonusDecodesUnchangedAndIsNotABonusPlan() throws {
        let f = try fixture(bonus: false)
        try validate(f)
        let data = try JSONEncoder().encode(f.state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("bonusMonths"))
        XCTAssertFalse(text.contains("bonusAmount"))
        let decoded = try JSONDecoder().decode(FinanceState.self, from: data)
        XCTAssertEqual(decoded, f.state)
        XCTAssertFalse(decoded.usesBonusPlans)
        XCTAssertTrue(decoded.usesInstallmentPlans)
    }

    func testBonusFieldsRoundTripThroughJSON() throws {
        let f = try fixture()
        let decoded = try JSONDecoder().decode(FinanceState.self, from: JSONEncoder().encode(f.state))
        XCTAssertEqual(decoded, f.state)
        XCTAssertEqual(decoded.contracts[0].bonusMonths, [6, 12])
        XCTAssertEqual(decoded.contracts[0].bonusAmount, 20_000)
    }

    func testRejectsInconsistentBonusFields() throws {
        var f = try fixture()
        f.state.contracts[0].bonusAmount = nil
        XCTAssertThrowsError(try validate(f), "months without amount")

        f = try fixture()
        f.state.contracts[0].bonusMonths = nil
        XCTAssertThrowsError(try validate(f), "amount without months")

        f = try fixture()
        f.state.contracts[0].bonusMonths = []
        XCTAssertThrowsError(try validate(f), "empty months")

        f = try fixture()
        f.state.contracts[0].bonusMonths = [12, 6]
        XCTAssertThrowsError(try validate(f), "months must be ascending")

        f = try fixture()
        f.state.contracts[0].bonusMonths = [6, 6]
        XCTAssertThrowsError(try validate(f), "months must be unique")

        f = try fixture()
        f.state.contracts[0].bonusMonths = [6, 13]
        XCTAssertThrowsError(try validate(f), "month out of range")

        f = try fixture()
        f.state.contracts[0].bonusMonths = [0, 6]
        XCTAssertThrowsError(try validate(f), "month out of range")

        f = try fixture()
        f.state.contracts[0].bonusAmount = 0
        XCTAssertThrowsError(try validate(f), "amount below 1")

        f = try fixture()
        f.state.contracts[0].bonusAmount = 110_001
        XCTAssertThrowsError(try validate(f), "amount above the total")
    }

    func testRejectsBonusFieldsOnAContractThatIsNotAPlan() throws {
        var f = try fixture(bonus: false)
        f.state = FinanceState(accounts: f.state.accounts,
            contracts: [FinanceContract(name: "端末", kind: .installment, categoryId: f.categories[0].id,
                expectedAmount: 1_000, startDate: start, firstDueDate: start,
                bonusMonths: [6], bonusAmount: 1_000)])
        XCTAssertThrowsError(try validate(f))
    }

    func testBonusPaymentsAreNeverRegenerated() throws {
        let f = try fixture()
        let far = Month.calendar.date(from: DateComponents(year: 2040, month: 1, day: 1))!
        XCTAssertEqual(try FinanceRules.generatePayments(f.state, through: far), f.state)
    }

    func testBonusMonthPaymentsCarryTheirPlannedInterestIntoTheMonthlyCost() throws {
        let f = try fixture()
        let december = f.state.payments[1]
        XCTAssertEqual(december.expectedAmount, 25_833)
        let cost = try FinanceRules.effectiveMonth(f.state, month: Month(date: december.dueDate)).contracts
        XCTAssertEqual(cost, december.plannedInterest)
        XCTAssertGreaterThan(cost, f.state.payments[0].plannedInterest ?? 0)
    }
}
