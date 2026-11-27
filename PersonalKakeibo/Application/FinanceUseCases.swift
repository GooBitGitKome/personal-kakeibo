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

}
