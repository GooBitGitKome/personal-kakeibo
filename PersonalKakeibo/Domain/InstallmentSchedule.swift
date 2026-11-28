import Foundation

/// One scheduled installment: the amount paid and how it splits into principal and interest/fee.
public struct InstallmentPayment: Equatable, Sendable {
    public let amount: Int64
    public let principal: Int64
    public let interest: Int64
}

/// Pure schedule calculation for an installment purchase.
///
/// - Every cycle pays `floor(total / cycles)` yen; the remainder is added to the last cycle.
/// - The interest/fee total (`total - principal`) is spread in proportion to the cycle amounts using
///   cumulative rounding. The cumulative difference of a proportional share is at most the cycle
///   amount, so interest never exceeds the payment and principal is never negative.
/// - The sums of amounts, principal and interest equal `total`, `principal` and `total - principal`
///   exactly.
public enum InstallmentSchedule {
    public static let cycleRange = 1...1_200

    public static func make(principal: Int64, total: Int64, cycles: Int) throws -> [InstallmentPayment] {
        guard cycleRange.contains(cycles), principal >= 0, total >= principal,
              total >= Int64(cycles)
        else { throw FinanceError.invalid }
        let count = Int64(cycles)
        let base = total / count
        let interestTotal = total - principal
        var result: [InstallmentPayment] = []
        result.reserveCapacity(cycles)
        var paid: Int64 = 0
        var allocatedInterest: Int64 = 0
        for index in 0..<cycles {
            let amount = index == cycles - 1 ? total - paid : base
            paid += amount
            let cumulativeInterest = try proportionalShare(of: interestTotal, numerator: paid, denominator: total)
            let interest = cumulativeInterest - allocatedInterest
            allocatedInterest = cumulativeInterest
            result.append(InstallmentPayment(amount: amount, principal: amount - interest, interest: interest))
        }
        return result
    }

    /// `floor((value * numerator + denominator / 2) / denominator)` without intermediate overflow.
    /// Requires `0 <= value`, `0 <= numerator <= denominator` and `denominator > 0`.
    static func proportionalShare(of value: Int64, numerator: Int64, denominator: Int64) throws -> Int64 {
        guard value >= 0, numerator >= 0, denominator > 0, numerator <= denominator
        else { throw FinanceError.invalid }
        let divisor = UInt64(denominator)
        let product = UInt64(value).multipliedFullWidth(by: UInt64(numerator))
        let (low, carry) = product.low.addingReportingOverflow(divisor / 2)
        let high = product.high &+ (carry ? 1 : 0)
        guard high < divisor else { throw FinanceError.overflow }
        let quotient = divisor.dividingFullWidth((high, low)).quotient
        guard quotient <= UInt64(Int64.max) else { throw FinanceError.overflow }
        return Int64(quotient)
    }
}
