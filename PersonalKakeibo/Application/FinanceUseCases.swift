import Foundation
import PersonalKakeiboDomain

@MainActor public struct FinanceUseCases {
    private let repository: any BackupRepository

    public init(repository: any BackupRepository) { self.repository = repository }

    private func apply(_ change: (inout BackupSnapshot) throws -> Void) throws {
        let original = try repository.snapshot()
        var next = original
        try change(&next)
        try FinanceRules.validate(next.finance, categories: next.categories, transactions: next.transactions)
        try repository.apply(next, expecting: original)
    }

    public func ensurePayments(through end: Date) throws {
        let original = try repository.snapshot()
        let generated = try FinanceRules.generatePayments(original.finance, through: end)
        guard generated != original.finance else { return }
        var next = original
        next.finance = generated
        try FinanceRules.validate(next.finance, categories: next.categories, transactions: next.transactions)
        try repository.apply(next, expecting: original)
    }

    public func saveAccount(_ account: FinanceAccount) throws {
        try apply { snapshot in
            snapshot.finance.accounts.removeAll { $0.id == account.id }
            snapshot.finance.accounts.append(account)
        }
    }

    public func saveContract(_ input: FinanceContract, effectiveFrom: Date = Date()) throws {
        try apply { snapshot in
            var contract = input
            let previous = snapshot.finance.contracts.first(where: { $0.id == input.id })
            if previous?.totalPayment != nil || input.totalPayment != nil {
                // Plans change only through the plan operations; descriptive text may still be edited.
                guard let previous, previous.totalPayment != nil else { throw FinanceError.invalid }
                var comparable = input
                comparable.name = previous.name; comparable.memo = previous.memo
                comparable.categoryId = previous.categoryId; comparable.necessity = previous.necessity
                comparable.usageFrequency = previous.usageFrequency; comparable.updatedAt = previous.updatedAt
                guard comparable == previous else { throw FinanceError.invalid }
            }
            if let old = snapshot.finance.contracts.first(where: { $0.id == input.id }) {
                let scheduleChanged = old.interval != input.interval ||
                    old.firstDueDate != input.firstDueDate || old.startDate != input.startDate
                if scheduleChanged {
                    contract.seriesId = UUID()
                    contract.generationStart = effectiveFrom
                    for index in snapshot.finance.payments.indices
                    where snapshot.finance.payments[index].contractId == input.id &&
                          snapshot.finance.payments[index].status == .pending &&
                          snapshot.finance.payments[index].dueDate >= effectiveFrom {
                        snapshot.finance.payments[index].status = .cancelled
                        snapshot.finance.payments[index].updatedAt = Date()
                    }
                } else {
                    contract.seriesId = old.seriesId
                }
            }
            snapshot.finance.contracts.removeAll { $0.id == contract.id }
            snapshot.finance.contracts.append(contract)
            if let oldPlanId = contract.replacedRecurringPlanId,
               let index = snapshot.recurringPlans.firstIndex(where: { $0.id == oldPlanId }) {
                snapshot.recurringPlans[index].isEnabled = false
                snapshot.recurringPlans[index].updatedAt = Date()
            }
            if contract.status == .ended {
                for index in snapshot.finance.payments.indices
                where snapshot.finance.payments[index].contractId == contract.id &&
                      snapshot.finance.payments[index].status == .pending {
                    snapshot.finance.payments[index].status = .cancelled
                }
            } else {
                let horizon = Month(date: effectiveFrom).shifted(13).start
                snapshot.finance = try FinanceRules.generatePayments(snapshot.finance, through: horizon)
            }
        }
    }

    public func saveAsset(_ asset: OwnedAsset) throws {
        try apply { snapshot in
            snapshot.finance.assets.removeAll { $0.id == asset.id }
            snapshot.finance.assets.append(asset)
        }
    }

    public func saveRepair(_ repair: AssetRepair) throws {
        try apply { snapshot in
            snapshot.finance.repairs.removeAll { $0.id == repair.id }
            snapshot.finance.repairs.append(repair)
        }
    }

    public func editPayment(_ expected: ScheduledPayment, amount: Int64, dueDate: Date) throws {
        try apply { snapshot in
            guard let index = snapshot.finance.payments.firstIndex(where: { $0.id == expected.id }),
                  snapshot.finance.payments[index] == expected, expected.status == .pending,
                  amount > 0 else { throw FinanceError.changed }
            snapshot.finance.payments[index].expectedAmount = amount
            snapshot.finance.payments[index].dueDate = dueDate
            snapshot.finance.payments[index].isOverridden = true
            snapshot.finance.payments[index].updatedAt = Date()
        }
    }

    public func skipPayment(_ expected: ScheduledPayment) throws {
        try apply { snapshot in
            guard let index = snapshot.finance.payments.firstIndex(where: { $0.id == expected.id }),
                  snapshot.finance.payments[index] == expected, expected.status == .pending
            else { throw FinanceError.changed }
            if snapshot.finance.contracts.first(where: { $0.id == expected.contractId })?.totalPayment != nil {
                // Skipping would leave principal unpaid; use cancel or change terms instead.
                throw FinanceError.invalid
            }
            snapshot.finance.payments[index].status = .skipped
            snapshot.finance.payments[index].updatedAt = Date()
        }
    }

    private static func postingAmount(_ amount: Int64, for account: FinanceAccount) throws -> Int64 {
        guard account.kind != .loan else { throw FinanceError.invalid }
        return account.kind == .creditCard ? amount : -amount
    }

    public func recordPayment(_ expected: ScheduledPayment, amount: Int64, categoryId: UUID,
                              date: Date, accountId: UUID?, principal: Int64? = nil,
                              memo: String = "") throws {
        try apply { snapshot in
            try Self.recordPayment(expected, amount: amount, categoryId: categoryId, date: date,
                                   accountId: accountId, principal: principal, memo: memo, in: &snapshot)
        }
    }

    private static func recordPayment(_ expected: ScheduledPayment, amount: Int64, categoryId: UUID,
                                      date: Date, accountId: UUID?, principal: Int64? = nil,
                                      memo: String = "", in snapshot: inout BackupSnapshot) throws {
            guard let index = snapshot.finance.payments.firstIndex(where: { $0.id == expected.id }),
                  snapshot.finance.payments[index] == expected, expected.status == .pending,
                  let contract = snapshot.finance.contracts.first(where: { $0.id == expected.contractId }),
                  amount > 0, memo.count <= 1_000
            else { throw FinanceError.changed }
            let account = accountId.flatMap { id in snapshot.finance.accounts.first { $0.id == id && !$0.isArchived } }
            if accountId != nil && account == nil { throw FinanceError.missing }
            snapshot.finance.payments[index].actualAmount = amount
            snapshot.finance.payments[index].status = .recorded
            snapshot.finance.payments[index].updatedAt = Date()
            if contract.kind == .loan || contract.kind == .installment {
                guard let account, account.kind == .bank || account.kind == .cash,
                      let liabilityId = contract.liabilityAccountId,
                      snapshot.finance.accounts.contains(where: { $0.id == liabilityId && $0.kind.isLiability }),
                      let principal, principal >= 0, principal <= amount
                else { throw FinanceError.invalid }
                let interest = amount - principal
                let eventId = UUID()
                snapshot.finance.postings.append(.init(accountId: account.id, eventId: eventId,
                    kind: .loanSettlement, date: date, amount: -amount))
                if principal > 0 {
                    snapshot.finance.postings.append(.init(accountId: liabilityId, eventId: eventId,
                        kind: .loanSettlement, date: date, amount: -principal))
                }
                snapshot.finance.payments[index].settlementEventId = eventId
                snapshot.finance.payments[index].principalAmount = principal
                snapshot.finance.payments[index].interestAmount = interest
                if interest > 0 {
                    let transaction = Transaction(type: .expense, amount: interest,
                        categoryId: categoryId, occurredAt: date, memo: memo, source: .lifecost)
                    try AmountValidator.validate(transaction,
                        category: snapshot.categories.first { $0.id == categoryId })
                    snapshot.transactions.append(transaction)
                    snapshot.finance.payments[index].transactionId = transaction.id
                }
            } else {
                let transaction = Transaction(type: .expense, amount: amount,
                    categoryId: categoryId, occurredAt: date, memo: memo, source: .lifecost)
                try AmountValidator.validate(transaction,
                    category: snapshot.categories.first { $0.id == categoryId })
                snapshot.transactions.append(transaction)
                snapshot.finance.payments[index].transactionId = transaction.id
                if let account {
                    snapshot.finance.postings.append(.init(accountId: account.id,
                        eventId: transaction.id, kind: .transaction, date: date,
                        amount: try Self.postingAmount(amount, for: account)))
                }
            }
            if contract.totalPayment != nil,
               let status = try snapshot.finance.installmentStatus(for: contract.id),
               status.remainingCount == 0 {
                // The last payment must settle the remaining principal exactly.
                guard status.remainingPrincipal == 0 else { throw FinanceError.invalid }
                try endContract(contract.id, in: &snapshot)
            }
    }

    public func recordSubscriptions(_ payments: [ScheduledPayment], month: Month) throws {
        guard !payments.isEmpty else { return }
        try apply { snapshot in
            guard Set(payments.map(\.id)).count == payments.count else { throw FinanceError.duplicate }
            for payment in payments {
                guard month.range.contains(payment.dueDate),
                      let contract = snapshot.finance.contracts.first(where: { $0.id == payment.contractId }),
                      contract.kind == .subscription, contract.status != .ended
                else { throw FinanceError.changed }
                try Self.recordPayment(payment, amount: payment.expectedAmount,
                    categoryId: contract.categoryId, date: payment.dueDate,
                    accountId: contract.paymentAccountId, memo: contract.name, in: &snapshot)
            }
        }
    }

    public func recordAutomaticSubscriptions(now: Date = Date()) throws {
        let original = try repository.snapshot()
        let month = Month(date: now)
        let eligible = Set(original.finance.contracts.filter {
            $0.kind == .subscription && $0.automaticallyRecordPayment == true &&
            !$0.isVariable && $0.status != .ended
        }.map(\.id))
        let payments = original.finance.payments.filter {
            $0.status == .pending && eligible.contains($0.contractId) &&
            month.range.contains($0.dueDate) && $0.dueDate <= now
        }
        try recordSubscriptions(payments, month: month)
    }

    public func recordManual(_ transaction: Transaction, accountId: UUID?) throws {
        try apply { snapshot in
            guard !snapshot.transactions.contains(where: { $0.id == transaction.id }) else { throw FinanceError.duplicate }
            try AmountValidator.validate(transaction,
                category: snapshot.categories.first { $0.id == transaction.categoryId })
            snapshot.transactions.append(transaction)
            if let accountId {
                guard let account = snapshot.finance.accounts.first(where: { $0.id == accountId && !$0.isArchived })
                else { throw FinanceError.missing }
                let amount = transaction.type == .expense
                    ? try Self.postingAmount(transaction.amount, for: account)
                    : (account.kind.isLiability ? -transaction.amount : transaction.amount)
                snapshot.finance.postings.append(.init(accountId: accountId, eventId: transaction.id,
                    kind: .transaction, date: transaction.occurredAt, amount: amount))
            }
        }
    }

    public func updateManual(_ transaction: Transaction, accountId: UUID?) throws {
        try apply { snapshot in
            guard let index = snapshot.transactions.firstIndex(where: { $0.id == transaction.id })
            else { throw FinanceError.missing }
            guard !snapshot.finance.payments.contains(where: { $0.transactionId == transaction.id })
            else { throw FinanceError.invalid }
            try AmountValidator.validate(transaction,
                category: snapshot.categories.first { $0.id == transaction.categoryId },
                previous: snapshot.transactions[index])
            snapshot.transactions[index] = transaction
            snapshot.finance.postings.removeAll { $0.eventId == transaction.id && $0.kind == .transaction }
            if let accountId {
                guard let account = snapshot.finance.accounts.first(where: { $0.id == accountId && !$0.isArchived })
                else { throw FinanceError.missing }
                let amount = transaction.type == .expense
                    ? try Self.postingAmount(transaction.amount, for: account)
                    : (account.kind.isLiability ? -transaction.amount : transaction.amount)
                snapshot.finance.postings.append(.init(accountId: accountId, eventId: transaction.id,
                    kind: .transaction, date: transaction.occurredAt, amount: amount))
            }
        }
    }

    public func transfer(amount: Int64, from sourceId: UUID, to destinationId: UUID, date: Date) throws {
        try apply { snapshot in
            guard amount > 0, sourceId != destinationId,
                  let source = snapshot.finance.accounts.first(where: { $0.id == sourceId && !$0.isArchived }),
                  let destination = snapshot.finance.accounts.first(where: { $0.id == destinationId && !$0.isArchived }),
                  !source.kind.isLiability, !destination.kind.isLiability
            else { throw FinanceError.invalid }
            let eventId = UUID()
            snapshot.finance.postings.append(.init(accountId: source.id, eventId: eventId,
                kind: .transfer, date: date, amount: -amount))
            snapshot.finance.postings.append(.init(accountId: destination.id, eventId: eventId,
                kind: .transfer, date: date, amount: amount))
        }
    }

    public func settleCard(amount: Int64, cardId: UUID, bankId: UUID, date: Date) throws {
        try apply { snapshot in
            guard amount > 0, cardId != bankId,
                  let card = snapshot.finance.accounts.first(where: { $0.id == cardId && $0.kind == .creditCard }),
                  let bank = snapshot.finance.accounts.first(where: { $0.id == bankId && ($0.kind == .bank || $0.kind == .cash) }),
                  try FinanceRules.accountBalance(card, postings: snapshot.finance.postings, asOf: date) >= amount
            else { throw FinanceError.invalid }
            let eventId = UUID()
            snapshot.finance.postings.append(.init(accountId: bank.id, eventId: eventId,
                kind: .cardSettlement, date: date, amount: -amount))
            snapshot.finance.postings.append(.init(accountId: card.id, eventId: eventId,
                kind: .cardSettlement, date: date, amount: -amount))
        }
    }

    public func refund(originalTransactionId: UUID, amount: Int64, date: Date,
                       accountId: UUID?, memo: String = "") throws {
        try apply { snapshot in
            guard amount > 0, memo.count <= 1_000,
                  let original = snapshot.transactions.first(where: { $0.id == originalTransactionId && $0.type == .expense }),
                  amount <= original.amount else { throw FinanceError.invalid }
            let existing = snapshot.finance.refunds.filter { $0.originalTransactionId == originalTransactionId }
            let returned = try existing.reduce(Int64(0)) { try FinanceRules.add($0, $1.amount) }
            guard try FinanceRules.add(returned, amount) <= original.amount else { throw FinanceError.invalid }
            let value = FinanceRefund(originalTransactionId: originalTransactionId,
                date: date, amount: amount, accountId: accountId, memo: memo)
            snapshot.finance.refunds.append(value)
            if let accountId {
                guard let account = snapshot.finance.accounts.first(where: { $0.id == accountId && !$0.isArchived })
                else { throw FinanceError.missing }
                let delta = account.kind.isLiability ? -amount : amount
                snapshot.finance.postings.append(.init(accountId: account.id, eventId: value.id,
                    kind: .refund, date: date, amount: delta))
            }
        }
    }

    // MARK: - Installment plans

    /// Input for registering an installment purchase.
    public struct InstallmentInput: Equatable, Sendable {
        public var name: String
        public var categoryId: UUID
        public var principal: Int64
        public var totalPayment: Int64
        public var cycles: Int
        public var purchaseDate: Date
        public var firstDueDate: Date
        public var paymentAccountId: UUID
        public var liabilityAccountId: UUID
        public var memo: String
        /// When set, an owned asset priced at `principal` is created and linked to the plan.
        public var asset: AssetInput?
        /// When set, the payments in `months` carry `amount` on top of the monthly part.
        public var bonus: BonusInput?

        public struct AssetInput: Equatable, Sendable {
            public var category: String
            public var usefulMonths: Int
            public var expectedResidual: Int64
            public init(category: String = "その他", usefulMonths: Int, expectedResidual: Int64 = 0) {
                self.category = category; self.usefulMonths = usefulMonths
                self.expectedResidual = expectedResidual
            }
        }

        /// An extra amount added to the payments that fall in the given months (1...12).
        public struct BonusInput: Equatable, Sendable {
            public var months: Set<Int>
            public var amount: Int64
            public init(months: Set<Int>, amount: Int64) {
                self.months = months; self.amount = amount
            }
        }

        public init(name: String, categoryId: UUID, principal: Int64, totalPayment: Int64, cycles: Int,
                    purchaseDate: Date, firstDueDate: Date, paymentAccountId: UUID,
                    liabilityAccountId: UUID, memo: String = "", asset: AssetInput? = nil,
                    bonus: BonusInput? = nil) {
            self.name = name; self.categoryId = categoryId; self.principal = principal
            self.totalPayment = totalPayment; self.cycles = cycles; self.purchaseDate = purchaseDate
            self.firstDueDate = firstDueDate; self.paymentAccountId = paymentAccountId
            self.liabilityAccountId = liabilityAccountId; self.memo = memo; self.asset = asset
            self.bonus = bonus
        }
    }

    /// Registers a plan: every payment, the purchase posting on the liability account and the
    /// optional asset are saved together. The principal is not recorded as an expense.
    @discardableResult
    public func registerInstallment(_ input: InstallmentInput) throws -> UUID {
        var contractId = UUID()
        try apply { snapshot in
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, input.principal >= 1,
                  (2...InstallmentSchedule.cycleRange.upperBound).contains(input.cycles),
                  input.memo.count <= 1_000,
                  let payer = snapshot.finance.accounts.first(where: { $0.id == input.paymentAccountId && !$0.isArchived }),
                  payer.kind == .bank || payer.kind == .cash,
                  let liability = snapshot.finance.accounts.first(where: { $0.id == input.liabilityAccountId && !$0.isArchived }),
                  liability.kind.isLiability
            else { throw FinanceError.invalid }
            let calendar = Month.calendar
            let purchaseDate = calendar.startOfDay(for: input.purchaseDate)
            let firstDue = calendar.startOfDay(for: input.firstDueDate)
            let dueDates = try (0..<input.cycles).map { try BillingInterval().date(from: firstDue, index: $0) }
            let schedule: [InstallmentPayment]
            var bonusMonths: [Int]?
            if let bonus = input.bonus {
                schedule = try BonusSchedule.make(principal: input.principal, total: input.totalPayment,
                    dueDates: dueDates, bonusMonths: bonus.months, bonusAmount: bonus.amount)
                bonusMonths = bonus.months.sorted()
            } else {
                schedule = try InstallmentSchedule.make(principal: input.principal,
                    total: input.totalPayment, cycles: input.cycles)
            }
            var assetId: UUID?
            if let draft = input.asset {
                let asset = OwnedAsset(name: name, category: draft.category, purchaseDate: purchaseDate,
                    purchasePrice: input.principal, expectedResidual: draft.expectedResidual,
                    usefulMonths: draft.usefulMonths)
                snapshot.finance.assets.append(asset)
                assetId = asset.id
            }
            let contract = FinanceContract(name: name, kind: .installment, categoryId: input.categoryId,
                expectedAmount: schedule[0].amount, startDate: purchaseDate, firstDueDate: firstDue,
                paymentAccountId: payer.id, liabilityAccountId: liability.id,
                memo: input.memo, financedAssetId: assetId, maximumCycles: input.cycles,
                principal: input.principal, totalPayment: input.totalPayment,
                bonusMonths: bonusMonths, bonusAmount: input.bonus?.amount)
            for (index, item) in schedule.enumerated() {
                let due = dueDates[index]
                snapshot.finance.payments.append(ScheduledPayment(contractId: contract.id,
                    seriesId: contract.seriesId, cycleIndex: index, dueDate: due, coverageStart: due,
                    expectedAmount: item.amount, plannedPrincipal: item.principal,
                    plannedInterest: item.interest))
            }
            snapshot.finance.contracts.append(contract)
            snapshot.finance.postings.append(.init(accountId: liability.id, eventId: contract.id,
                kind: .installmentPurchase, date: purchaseDate, amount: input.principal))
            contractId = contract.id
        }
        return contractId
    }

    /// Pending payments and remaining principal of a plan, checked against what the caller showed.
    private static func openPlan(_ contractId: UUID, expectedPendingCount: Int, expectedRemainingPrincipal: Int64,
                                 in snapshot: BackupSnapshot) throws -> (contract: FinanceContract, status: InstallmentStatus) {
        guard let contract = snapshot.finance.contracts.first(where: { $0.id == contractId }),
              let status = try snapshot.finance.installmentStatus(for: contractId)
        else { throw FinanceError.missing }
        guard status.remainingCount == expectedPendingCount,
              status.remainingPrincipal == expectedRemainingPrincipal
        else { throw FinanceError.changed }
        guard status.remainingCount > 0, contract.status != .ended else { throw FinanceError.invalid }
        return (contract, status)
    }

    private static func cancelPending(_ contractId: UUID, in snapshot: inout BackupSnapshot) {
        let now = Date()
        for index in snapshot.finance.payments.indices
        where snapshot.finance.payments[index].contractId == contractId &&
              snapshot.finance.payments[index].status == .pending {
            snapshot.finance.payments[index].status = .cancelled
            snapshot.finance.payments[index].updatedAt = now
        }
    }

    private static func endContract(_ contractId: UUID, in snapshot: inout BackupSnapshot) throws {
        guard let index = snapshot.finance.contracts.firstIndex(where: { $0.id == contractId })
        else { throw FinanceError.missing }
        snapshot.finance.contracts[index].status = .ended
        snapshot.finance.contracts[index].updatedAt = Date()
    }

    /// Cancels every pending payment and releases the remaining principal from the liability account.
    /// Recorded payments are left untouched.
    public func cancelInstallment(_ contractId: UUID, date: Date, expectedPendingCount: Int,
                                  expectedRemainingPrincipal: Int64) throws {
        try apply { snapshot in
            let (contract, status) = try Self.openPlan(contractId, expectedPendingCount: expectedPendingCount,
                expectedRemainingPrincipal: expectedRemainingPrincipal, in: snapshot)
            guard let liabilityId = contract.liabilityAccountId else { throw FinanceError.invalid }
            Self.cancelPending(contractId, in: &snapshot)
            if status.remainingPrincipal > 0 {
                snapshot.finance.postings.append(.init(accountId: liabilityId, eventId: contractId,
                    kind: .installmentCancellation, date: Month.calendar.startOfDay(for: date),
                    amount: -status.remainingPrincipal))
            }
            try Self.endContract(contractId, in: &snapshot)
        }
    }

    /// Pays the remaining principal plus an optional fee at once and cancels the pending payments.
    /// The principal is not an expense; the fee is.
    public func prepayInstallment(_ contractId: UUID, date: Date, fee: Int64, memo: String = "",
                                  expectedPendingCount: Int, expectedRemainingPrincipal: Int64) throws {
        try apply { snapshot in
            let (contract, status) = try Self.openPlan(contractId, expectedPendingCount: expectedPendingCount,
                expectedRemainingPrincipal: expectedRemainingPrincipal, in: snapshot)
            guard fee >= 0, memo.count <= 1_000, status.remainingPrincipal > 0,
                  let payerId = contract.paymentAccountId, let liabilityId = contract.liabilityAccountId
            else { throw FinanceError.invalid }
            let day = Month.calendar.startOfDay(for: date)
            let total = try FinanceRules.add(status.remainingPrincipal, fee)
            let eventId = UUID()
            let nextIndex = (snapshot.finance.payments.filter { $0.seriesId == contract.seriesId }
                .map(\.cycleIndex).max() ?? -1) + 1
            var payment = ScheduledPayment(contractId: contractId, seriesId: contract.seriesId,
                cycleIndex: nextIndex, dueDate: day, coverageStart: day, expectedAmount: total,
                actualAmount: total, principalAmount: status.remainingPrincipal, interestAmount: fee,
                status: .recorded, settlementEventId: eventId)
            Self.cancelPending(contractId, in: &snapshot)
            snapshot.finance.postings.append(.init(accountId: payerId, eventId: eventId,
                kind: .loanSettlement, date: day, amount: -total))
            snapshot.finance.postings.append(.init(accountId: liabilityId, eventId: eventId,
                kind: .loanSettlement, date: day, amount: -status.remainingPrincipal))
            if fee > 0 {
                let transaction = Transaction(type: .expense, amount: fee, categoryId: contract.categoryId,
                    occurredAt: day, memo: memo.isEmpty ? contract.name + "（繰上返済手数料）" : memo,
                    source: .lifecost)
                try AmountValidator.validate(transaction,
                    category: snapshot.categories.first { $0.id == contract.categoryId })
                snapshot.transactions.append(transaction)
                payment.transactionId = transaction.id
            }
            snapshot.finance.payments.append(payment)
            try Self.endContract(contractId, in: &snapshot)
        }
    }

    /// Replaces the pending payments using the remaining principal and a new remaining total and
    /// cycle count. Recorded payments and the remaining principal do not change.
    public func changeInstallmentTerms(_ contractId: UUID, remainingTotal: Int64, remainingCycles: Int,
                                       expectedPendingCount: Int, expectedRemainingPrincipal: Int64) throws {
        try apply { snapshot in
            let (contract, status) = try Self.openPlan(contractId, expectedPendingCount: expectedPendingCount,
                expectedRemainingPrincipal: expectedRemainingPrincipal, in: snapshot)
            // Bonus plans have no term change; they are cancelled and registered again.
            guard contract.bonusAmount == nil else { throw FinanceError.invalid }
            guard let firstPending = snapshot.finance.payments
                .filter({ $0.contractId == contractId && $0.status == .pending })
                .min(by: { $0.dueDate < $1.dueDate })
            else { throw FinanceError.invalid }
            let schedule = try InstallmentSchedule.make(principal: status.remainingPrincipal,
                total: remainingTotal, cycles: remainingCycles)
            let recorded = snapshot.finance.payments.filter { $0.contractId == contractId && $0.status == .recorded }
            let recordedAmount = try recorded.reduce(Int64(0)) {
                try FinanceRules.add($0, $1.actualAmount ?? $1.expectedAmount)
            }
            Self.cancelPending(contractId, in: &snapshot)
            guard let index = snapshot.finance.contracts.firstIndex(where: { $0.id == contractId })
            else { throw FinanceError.missing }
            snapshot.finance.contracts[index].seriesId = UUID()
            snapshot.finance.contracts[index].expectedAmount = schedule[0].amount
            snapshot.finance.contracts[index].maximumCycles = recorded.count + remainingCycles
            snapshot.finance.contracts[index].totalPayment = try FinanceRules.add(recordedAmount, remainingTotal)
            snapshot.finance.contracts[index].updatedAt = Date()
            let seriesId = snapshot.finance.contracts[index].seriesId
            for (offset, item) in schedule.enumerated() {
                let due = try contract.interval.date(from: firstPending.dueDate, index: offset)
                snapshot.finance.payments.append(ScheduledPayment(contractId: contractId,
                    seriesId: seriesId, cycleIndex: offset, dueDate: due, coverageStart: due,
                    expectedAmount: item.amount, plannedPrincipal: item.principal,
                    plannedInterest: item.interest))
            }
        }
    }
}
