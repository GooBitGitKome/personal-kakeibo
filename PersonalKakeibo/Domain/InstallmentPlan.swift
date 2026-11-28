import Foundation

/// Progress of an installment plan, derived from the recorded and pending payments.
public struct InstallmentStatus: Equatable, Sendable {
    public let paidCount: Int
    public let remainingCount: Int
    /// Sum of the pending payments' expected amounts.
    public let remainingPayment: Int64
    /// Purchase amount minus recorded principal minus principal released by a cancellation.
    public let remainingPrincipal: Int64

    public init(paidCount: Int, remainingCount: Int, remainingPayment: Int64, remainingPrincipal: Int64) {
        self.paidCount = paidCount; self.remainingCount = remainingCount
        self.remainingPayment = remainingPayment; self.remainingPrincipal = remainingPrincipal
    }
}

public extension FinanceState {
    /// Nil when the contract is not an installment plan (`totalPayment == nil`).
    func installmentStatus(for contractId: UUID) throws -> InstallmentStatus? {
        guard let contract = contracts.first(where: { $0.id == contractId }),
              contract.totalPayment != nil, let principal = contract.principal
        else { return nil }
        var paid = 0, pending = 0
        var remainingPayment: Int64 = 0, settledPrincipal: Int64 = 0
        for payment in payments where payment.contractId == contractId {
            switch payment.status {
            case .recorded:
                paid += 1
                settledPrincipal = try FinanceRules.add(settledPrincipal, payment.principalAmount ?? 0)
            case .pending:
                pending += 1
                remainingPayment = try FinanceRules.add(remainingPayment, payment.expectedAmount)
            case .skipped, .cancelled:
                break
            }
        }
        for posting in postings where posting.eventId == contractId && posting.kind == .installmentCancellation {
            settledPrincipal = try FinanceRules.add(settledPrincipal, -posting.amount)
        }
        return InstallmentStatus(paidCount: paid, remainingCount: pending,
            remainingPayment: remainingPayment, remainingPrincipal: principal - settledPrincipal)
    }

    /// Initial principal/interest split offered when confirming a pending plan payment for `amount`.
    /// The planned principal is used, limited to what is still owed; the last pending payment
    /// offers all remaining principal. The split never gives negative interest.
    func suggestedSplit(for payment: ScheduledPayment, amount: Int64) throws -> (principal: Int64, interest: Int64)? {
        guard payment.status == .pending, let status = try installmentStatus(for: payment.contractId)
        else { return nil }
        let planned = payment.plannedPrincipal ?? 0
        let candidate = status.remainingCount == 1 ? status.remainingPrincipal : min(planned, status.remainingPrincipal)
        let principal = max(0, min(candidate, amount))
        return (principal, amount - principal)
    }
}
