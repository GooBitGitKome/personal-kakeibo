import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class BonusScheduleTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func monthlyDates(from start: Date, count: Int) throws -> [Date] {
        try (0..<count).map { try BillingInterval().date(from: start, index: $0) }
    }

    private func assertInvariants(_ schedule: [InstallmentPayment], principal: Int64, total: Int64,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(schedule.reduce(0) { $0 + $1.amount }, total, file: file, line: line)
        XCTAssertEqual(schedule.reduce(0) { $0 + $1.principal }, principal, file: file, line: line)
        XCTAssertEqual(schedule.reduce(0) { $0 + $1.interest }, total - principal, file: file, line: line)
        for payment in schedule {
            XCTAssertGreaterThan(payment.amount, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(payment.interest, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(payment.principal, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(payment.interest, payment.amount, file: file, line: line)
        }
    }

    // MARK: split over arbitrary amounts

    func testSplitMatchesMakeForEvenCycles() throws {
        let made = try InstallmentSchedule.make(principal: 100_000, total: 100_003, cycles: 3)
        let split = try InstallmentSchedule.split(principal: 100_000, amounts: [33_334, 33_334, 33_335])
        XCTAssertEqual(made, split)
    }

    func testSplitInvariantsForEveryUnevenSmallInput() throws {
        for count in 1...4 {
            var amounts = [Int64](repeating: 1, count: count)
            func visit(_ index: Int) throws {
                if index == count {
                    let total = amounts.reduce(0, +)
                    for principal in Int64(0)...total {
                        assertInvariants(try InstallmentSchedule.split(principal: principal, amounts: amounts),
                                         principal: principal, total: total)
                    }
                    return
                }
                for value in Int64(1)...6 { amounts[index] = value; try visit(index + 1) }
            }
            try visit(0)
        }
    }

    func testSplitRejectsInvalidAmounts() {
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: 10, amounts: []))
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: 10, amounts: [5, 0, 5]))
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: 11, amounts: [5, 5]))
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: -1, amounts: [5, 5]))
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: 0,
            amounts: [Int64](repeating: 1, count: 1_201)))
        XCTAssertThrowsError(try InstallmentSchedule.split(principal: 0, amounts: [Int64.max, 1]))
    }

    // MARK: bonus schedule

    func testJuneAndDecemberExample() throws {
        let dates = try monthlyDates(from: date(2026, 11, 1), count: 12)
        let schedule = try BonusSchedule.make(principal: 100_000, total: 110_000, dueDates: dates,
                                              bonusMonths: [6, 12], bonusAmount: 20_000)
        var expected = [Int64](repeating: 5_833, count: 12)
        expected[1] = 25_833   // 2026-12
        expected[7] = 25_833   // 2027-06
        expected[11] = 5_837   // last payment gets the 4 yen remainder
        XCTAssertEqual(schedule.map(\.amount), expected)
        assertInvariants(schedule, principal: 100_000, total: 110_000)
    }

    func testLastPaymentInABonusMonthGetsRemainderAndBonus() throws {
        let dates = try monthlyDates(from: date(2026, 11, 1), count: 8)
        let schedule = try BonusSchedule.make(principal: 70_000, total: 80_003, dueDates: dates,
                                              bonusMonths: [6], bonusAmount: 10_000)
        XCTAssertEqual(schedule.map(\.amount), Array(repeating: 8_750, count: 7) + [18_753])
        assertInvariants(schedule, principal: 70_000, total: 80_003)
    }

    func testMonthEndDueDateStillFallsInTheBonusMonth() throws {
        let dates = try monthlyDates(from: date(2026, 1, 31), count: 3)
        XCTAssertEqual(dates[1], date(2026, 2, 28))
        XCTAssertEqual(BonusSchedule.bonusFlags(dueDates: dates, bonusMonths: [2]), [false, true, false])
    }

    func testTinyPrincipalWithLargeInterest() throws {
        let dates = try monthlyDates(from: date(2026, 11, 1), count: 5)
        let schedule = try BonusSchedule.make(principal: 1, total: 20, dueDates: dates,
                                              bonusMonths: [12], bonusAmount: 2)
        XCTAssertEqual(schedule.map(\.amount), [3, 5, 3, 3, 6])
        assertInvariants(schedule, principal: 1, total: 20)
    }

    func testRejectsInvalidBonusInput() throws {
        let year = try monthlyDates(from: date(2026, 11, 1), count: 12)
        let short = try monthlyDates(from: date(2026, 11, 1), count: 3)
        // no bonus month inside the period
        XCTAssertThrowsError(try BonusSchedule.make(principal: 100, total: 200, dueDates: short,
            bonusMonths: [6], bonusAmount: 10))
        // bonus amount below 1, empty or out-of-range months
        XCTAssertThrowsError(try BonusSchedule.make(principal: 100, total: 200, dueDates: year,
            bonusMonths: [6], bonusAmount: 0))
        XCTAssertThrowsError(try BonusSchedule.make(principal: 100, total: 200, dueDates: year,
            bonusMonths: [], bonusAmount: 10))
        XCTAssertThrowsError(try BonusSchedule.make(principal: 100, total: 200, dueDates: year,
            bonusMonths: [13], bonusAmount: 10))
        XCTAssertThrowsError(try BonusSchedule.make(principal: 100, total: 200, dueDates: year,
            bonusMonths: [0], bonusAmount: 10))
        // the monthly part would be smaller than the number of payments
        XCTAssertThrowsError(try BonusSchedule.make(principal: 40_000, total: 50_000, dueDates: year,
            bonusMonths: [6, 12], bonusAmount: 24_999))
        // total smaller than the bonus extras, or smaller than the principal
        XCTAssertThrowsError(try BonusSchedule.make(principal: 1, total: 10, dueDates: year,
            bonusMonths: [6, 12], bonusAmount: 20))
        XCTAssertThrowsError(try BonusSchedule.make(principal: 300, total: 200, dueDates: year,
            bonusMonths: [6], bonusAmount: 10))
        // overflow
        XCTAssertThrowsError(try BonusSchedule.make(principal: 1, total: Int64.max, dueDates: year,
            bonusMonths: [6, 12], bonusAmount: Int64.max))
    }

    func testInvariantsHoldAcrossPeriodsMonthSetsAndAmounts() throws {
        let monthSets: [Set<Int>] = [[6, 12], [1], [3, 7, 11], Set(1...12)]
        for count in 1...14 {
            let dates = try monthlyDates(from: date(2026, 11, 1), count: count)
            for months in monthSets {
                for bonus in [Int64(1), 7, 100] {
                    for total in stride(from: Int64(count), to: 600, by: 17) {
                        let schedule: [InstallmentPayment]
                        do {
                            schedule = try BonusSchedule.make(principal: total / 2, total: total,
                                dueDates: dates, bonusMonths: months, bonusAmount: bonus)
                        } catch FinanceError.invalid {
                            continue
                        }
                        assertInvariants(schedule, principal: total / 2, total: total)
                        for principal in [Int64(0), 1, total] {
                            assertInvariants(try BonusSchedule.make(principal: principal, total: total,
                                dueDates: dates, bonusMonths: months, bonusAmount: bonus),
                                principal: principal, total: total)
                        }
                    }
                }
            }
        }
    }
}
