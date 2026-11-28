import Foundation

/// Pure schedule calculation for an installment plan with an extra amount in bonus months.
///
/// - A payment is a bonus-month payment when the month of its due date (Asia/Tokyo) is one of the
///   bonus months. Let `k` be the number of such payments and `X` the bonus amount.
/// - The monthly part is `total - k * X`, divided by the number of payments and rounded down. The
///   remainder goes to the last payment. Bonus-month payments add `X` on top.
/// - Principal and interest are then split in proportion to the payment amounts, exactly as for a
///   plain installment plan.
public enum BonusSchedule {
    public static let months = 1...12

    /// Which payments fall in a bonus month.
    public static func bonusFlags(dueDates: [Date], bonusMonths: Set<Int>) -> [Bool] {
        let calendar = Month.calendar
        return dueDates.map { bonusMonths.contains(calendar.component(.month, from: $0)) }
    }

    public static func amounts(total: Int64, dueDates: [Date], bonusMonths: Set<Int>,
                               bonusAmount: Int64) throws -> [Int64] {
        let count = dueDates.count
        guard InstallmentSchedule.cycleRange.contains(count), !bonusMonths.isEmpty,
              bonusMonths.allSatisfy({ months.contains($0) }), bonusAmount >= 1
        else { throw FinanceError.invalid }
        let flags = bonusFlags(dueDates: dueDates, bonusMonths: bonusMonths)
        let bonusCount = flags.filter { $0 }.count
        guard bonusCount >= 1 else { throw FinanceError.invalid }
        let bonusTotal = bonusAmount.multipliedReportingOverflow(by: Int64(bonusCount))
        guard !bonusTotal.overflow else { throw FinanceError.overflow }
        guard total >= bonusTotal.partialValue else { throw FinanceError.invalid }
        let monthlyTotal = total - bonusTotal.partialValue
        guard monthlyTotal >= Int64(count) else { throw FinanceError.invalid }
        let base = monthlyTotal / Int64(count)
        var result: [Int64] = []
        result.reserveCapacity(count)
        for (index, isBonus) in flags.enumerated() {
            var amount = base
            if index == count - 1 { amount = try FinanceRules.add(amount, monthlyTotal - base * Int64(count)) }
            if isBonus { amount = try FinanceRules.add(amount, bonusAmount) }
            result.append(amount)
        }
        return result
    }

    public static func make(principal: Int64, total: Int64, dueDates: [Date], bonusMonths: Set<Int>,
                            bonusAmount: Int64) throws -> [InstallmentPayment] {
        let values = try amounts(total: total, dueDates: dueDates, bonusMonths: bonusMonths,
                                 bonusAmount: bonusAmount)
        return try InstallmentSchedule.split(principal: principal, amounts: values)
    }
}
