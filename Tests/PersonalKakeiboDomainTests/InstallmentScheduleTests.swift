import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class InstallmentScheduleTests: XCTestCase {
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
            XCTAssertEqual(payment.principal + payment.interest, payment.amount, file: file, line: line)
        }
    }

    func testRemainderGoesToTheLastCycle() throws {
        let schedule = try InstallmentSchedule.make(principal: 100_000, total: 100_003, cycles: 3)
        XCTAssertEqual(schedule.map(\.amount), [33_334, 33_334, 33_335])
        XCTAssertEqual(schedule.map(\.interest), [1, 1, 1])
        assertInvariants(schedule, principal: 100_000, total: 100_003)
    }

    func testEvenSplitWithInterest() throws {
        let schedule = try InstallmentSchedule.make(principal: 100_000, total: 110_000, cycles: 10)
        XCTAssertEqual(schedule.map(\.amount), Array(repeating: 11_000, count: 10))
        XCTAssertEqual(schedule.map(\.interest), Array(repeating: 1_000, count: 10))
        XCTAssertEqual(schedule.map(\.principal), Array(repeating: 10_000, count: 10))
    }

    func testNoInterestWhenTotalEqualsPrincipal() throws {
        let schedule = try InstallmentSchedule.make(principal: 30_001, total: 30_001, cycles: 7)
        XCTAssertTrue(schedule.allSatisfy { $0.interest == 0 })
        assertInvariants(schedule, principal: 30_001, total: 30_001)
    }

    func testTinyPrincipalWithLargeInterest() throws {
        let schedule = try InstallmentSchedule.make(principal: 1, total: 20, cycles: 5)
        assertInvariants(schedule, principal: 1, total: 20)
    }

    /// Exhaustive over small inputs: the sums are exact and interest never exceeds a payment.
    func testInvariantsHoldForEverySmallInput() throws {
        for cycles in 1...14 {
            for total in Int64(cycles)...60 {
                for principal in Int64(0)...total {
                    let schedule = try InstallmentSchedule.make(principal: principal, total: total, cycles: cycles)
                    XCTAssertEqual(schedule.count, cycles)
                    assertInvariants(schedule, principal: principal, total: total)
                }
            }
        }
    }

    func testBoundaryInputs() throws {
        let maximumCycles = try InstallmentSchedule.make(principal: 1, total: 1_200, cycles: 1_200)
        assertInvariants(maximumCycles, principal: 1, total: 1_200)
        let large = try InstallmentSchedule.make(principal: 1, total: 1_234_567_890, cycles: 1_200)
        assertInvariants(large, principal: 1, total: 1_234_567_890)
        let huge = try InstallmentSchedule.make(principal: Int64.max / 3, total: Int64.max, cycles: 1_200)
        assertInvariants(huge, principal: Int64.max / 3, total: Int64.max)
        let single = try InstallmentSchedule.make(principal: 500, total: 520, cycles: 1)
        XCTAssertEqual(single, [InstallmentPayment(amount: 520, principal: 500, interest: 20)])
    }

    func testRejectsOutOfRangeInput() {
        XCTAssertThrowsError(try InstallmentSchedule.make(principal: 100, total: 99, cycles: 3))
        XCTAssertThrowsError(try InstallmentSchedule.make(principal: -1, total: 99, cycles: 3))
        XCTAssertThrowsError(try InstallmentSchedule.make(principal: 1, total: 2, cycles: 3))
        XCTAssertThrowsError(try InstallmentSchedule.make(principal: 10, total: 10, cycles: 0))
        XCTAssertThrowsError(try InstallmentSchedule.make(principal: 10, total: 10_000, cycles: 1_201))
    }
}
