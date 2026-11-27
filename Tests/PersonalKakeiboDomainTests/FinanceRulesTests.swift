import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class FinanceRulesTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testMonthlyContractTotalNormalizesPeriodsAndExcludesEnded() throws {
        let category = UUID()
        let now = date(2026, 10, 26)
        func contract(_ amount: Int64, _ interval: BillingInterval = .init(),
                      status: ContractStatus = .active) -> FinanceContract {
            FinanceContract(name: "テスト", kind: .subscription, categoryId: category,
                            expectedAmount: amount, interval: interval, startDate: now,
                            firstDueDate: now, status: status)
        }
        let contracts = [contract(1_000), contract(12_000, .init(unit: .year)),
                         contract(3_000, .init(count: 3), status: .cancellationPlanned),
                         contract(99_999, status: .ended)]
        XCTAssertEqual(try FinanceRules.monthlyContractTotal(contracts), 3_000)
        XCTAssertEqual(try FinanceRules.monthlyContractTotal([]), .zero)
        let thirds = (0..<3).map { _ in contract(1, .init(count: 3)) }
        let total = try FinanceRules.monthlyContractTotal(thirds)
        XCTAssertTrue(total > Decimal(string: "0.999999999999")!)
        XCTAssertTrue(total <= 1)
        XCTAssertEqual(try FinanceRules.monthlyContractTotal([contract(Int64.max), contract(Int64.max)]),
                       Decimal(Int64.max) * 2)
    }

    func testBillingAnchorsAndMonthlyEquivalent() throws {
        let january = date(2025, 1, 31)
        let monthly = BillingInterval(count: 1, unit: .month)
        XCTAssertEqual(try monthly.date(from: january, index: 1), date(2025, 2, 28))
        XCTAssertEqual(try monthly.date(from: january, index: 2), date(2025, 3, 31))
        let leap = date(2024, 2, 29)
        XCTAssertEqual(try BillingInterval(unit: .year).date(from: leap, index: 1),
                       date(2025, 2, 28))
        XCTAssertEqual(try BillingInterval(unit: .year).date(from: leap, index: 4),
                       date(2028, 2, 29))
        XCTAssertEqual(try BillingInterval(unit: .year).monthlyEquivalent(12_000),
                       Decimal(1_000))
        XCTAssertEqual(try BillingInterval(count: 3, unit: .month).monthlyEquivalent(3_000),
                       Decimal(1_000))
        let weekly = try BillingInterval(unit: .week).monthlyEquivalent(1_000)
        XCTAssertTrue(weekly > 4_300 && weekly < 4_400)
    }

    func testAssetAllocationSumsExactlyAndAnnualExample() throws {
        let purchase = date(2026, 1, 15)
        let asset = OwnedAsset(name: "パソコン", purchaseDate: purchase,
            purchasePrice: 120_000, usefulMonths: 72)
        let state = FinanceState(assets: [asset])
        let firstYear = try (0..<12).reduce(Int64(0)) { total, index in
            try FinanceRules.add(total,
                FinanceRules.effectiveMonth(state, month: Month(date:
                    Month.calendar.date(byAdding: .month, value: index, to: purchase)!)).assets)
        }
        XCTAssertEqual(firstYear, 20_000)
        let lifetime = try (0..<72).reduce(Int64(0)) { total, index in
            try FinanceRules.add(total, FinanceRules.allocatedYen(120_000, months: 72, index: index))
        }
        XCTAssertEqual(lifetime, 120_000)
        XCTAssertEqual(try FinanceRules.effectiveMonth(state,
            month: Month(date: date(2032, 1, 1))).assets, 0)
    }

    func testActualBillReplacesEstimateAndLoanPrincipalDoesNotDoubleCount() throws {
        let category = UUID()
        let start = date(2026, 10, 1)
        let utility = FinanceContract(name: "電気", kind: .fixedCost,
            categoryId: category, expectedAmount: 1_000,
            isVariable: true, startDate: start, firstDueDate: start)
        let loan = FinanceContract(name: "端末分割", kind: .installment,
            categoryId: category, expectedAmount: 10_000,
            startDate: start, firstDueDate: start, maximumCycles: 12)
        let utilityPayment = ScheduledPayment(contractId: utility.id, seriesId: utility.seriesId,
            cycleIndex: 0, dueDate: start, coverageStart: start,
            expectedAmount: 1_000, actualAmount: 1_200, status: .recorded,
            transactionId: UUID())
        let loanPayment = ScheduledPayment(contractId: loan.id, seriesId: loan.seriesId,
            cycleIndex: 0, dueDate: start, coverageStart: start,
            expectedAmount: 10_000, actualAmount: 10_100,
            principalAmount: 10_000, interestAmount: 100,
            status: .recorded, transactionId: UUID(), settlementEventId: UUID())
        let state = FinanceState(contracts: [utility, loan],
            payments: [utilityPayment, loanPayment])
        let cost = try FinanceRules.effectiveMonth(state, month: Month(date: start))
        XCTAssertEqual(cost.contracts, 1_300)
    }

    func testCardPostingAndRefundKeepSpendAndCashSeparate() throws {
        let date = date(2026, 10, 1)
        let bank = FinanceAccount(name: "銀行", kind: .bank, openingDate: date,
            openingBalance: 100_000)
        let card = FinanceAccount(name: "カード", kind: .creditCard, openingDate: date,
            openingBalance: 0)
        let purchase = Transaction(type: .expense, amount: 12_000,
            categoryId: UUID(), occurredAt: date)
        let settlement = UUID()
        let refund = FinanceRefund(originalTransactionId: purchase.id, date: date,
            amount: 2_000, accountId: card.id)
        let postings: [AccountPosting] = [
            .init(accountId: card.id, eventId: purchase.id, kind: .transaction,
                  date: date, amount: 12_000),
            .init(accountId: bank.id, eventId: settlement, kind: .cardSettlement,
                  date: date, amount: -10_000),
            .init(accountId: card.id, eventId: settlement, kind: .cardSettlement,
                  date: date, amount: -10_000),
            .init(accountId: card.id, eventId: refund.id, kind: .refund,
                  date: date, amount: -2_000)
        ]
        XCTAssertEqual(try FinanceRules.accountBalance(bank, postings: postings, asOf: date),
                       90_000)
        XCTAssertEqual(try FinanceRules.accountBalance(card, postings: postings, asOf: date), 0)
        let month = Month(date: date)
        let summary = try MonthlySummary.calculate([purchase], in: month.range, refunds: [refund])
        XCTAssertEqual(summary.expense, 10_000)
        XCTAssertEqual(summary.income, 0)
    }
}
