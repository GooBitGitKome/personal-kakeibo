import Foundation

public struct EffectiveMonth: Equatable, Sendable {
    public let contracts: Int64
    public let assets: Int64
    public var total: Int64 { contracts + assets }
}

public enum FinanceRules {
    /// Comparison estimate across billing intervals, excluding contracts marked ended.
    /// Sum before rounding so category and overall totals retain fractional yen.
    public static func monthlyContractTotal(_ contracts: [FinanceContract]) throws -> Decimal {
        try contracts.filter { $0.status != .ended }.reduce(Decimal.zero) { total, contract in
            total + (try contract.interval.monthlyEquivalent(contract.expectedAmount))
        }
    }

    public static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw FinanceError.overflow }
        return result.partialValue
    }

    private static func unique<T: Identifiable>(_ values: [T]) -> Bool where T.ID == UUID {
        Set(values.map(\.id)).count == values.count
    }

    public static func validate(_ state: FinanceState, categories: [Category], transactions: [Transaction]) throws {
        guard state.accounts.count <= 10_000, state.postings.count <= 100_000,
              state.contracts.count <= 10_000, state.payments.count <= 10_000,
              state.assets.count <= 10_000, state.repairs.count <= 10_000,
              state.refunds.count <= 10_000,
              unique(state.accounts), unique(state.postings), unique(state.contracts),
              unique(state.payments), unique(state.assets), unique(state.repairs),
              unique(state.refunds),
              Set(state.payments.map(\.key)).count == state.payments.count,
              Set(state.importedDatasetIds).count == state.importedDatasetIds.count
        else { throw FinanceError.duplicate }

        let accountIds = Set(state.accounts.map(\.id))
        let contracts = Dictionary(uniqueKeysWithValues: state.contracts.map { ($0.id, $0) })
        let assets = Set(state.assets.map(\.id))
        let categoriesById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let transactionIds = Set(transactions.map(\.id))
        let refundIds = Set(state.refunds.map(\.id))
        for account in state.accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.name.count <= 100, account.openingBalance >= 0,
                  Planning.isSupportedDate(account.openingDate) else { throw FinanceError.invalid }
        }
        for posting in state.postings {
            guard accountIds.contains(posting.accountId), posting.amount != 0,
                  Planning.isSupportedDate(posting.date) else { throw FinanceError.invalid }
            if posting.kind == .transaction || posting.kind == .refund {
                guard (posting.kind == .transaction ? transactionIds : refundIds).contains(posting.eventId)
                else { throw FinanceError.missing }
            }
        }
        for contract in state.contracts {
            guard !contract.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  contract.name.count <= 100, contract.expectedAmount > 0,
                  contract.memo.count <= 1_000, contract.necessity.count <= 100,
                  contract.usageFrequency.count <= 100,
                  categoriesById[contract.categoryId]?.type == .expense,
                  Planning.isSupportedDate(contract.startDate),
                  Planning.isSupportedDate(contract.firstDueDate),
                  contract.endDate.map({ $0 >= contract.startDate }) ?? true,
                  contract.paymentAccountId.map({ accountIds.contains($0) }) ?? true,
                  contract.liabilityAccountId.map({ accountIds.contains($0) }) ?? true,
                  contract.financedAssetId.map({ assets.contains($0) }) ?? true,
                  contract.maximumCycles.map({ (1...10_000).contains($0) }) ?? true,
                  contract.finalAmount.map({ $0 > 0 }) ?? true,
                  contract.principal.map({ $0 > 0 }) ?? true,
                  contract.kind == .insurance || contract.insurance == nil
            else { throw FinanceError.invalid }
            _ = try contract.interval.date(from: contract.firstDueDate, index: 1)
            if let policy = contract.insurance {
                guard policy.company.count <= 100, policy.productName.count <= 100,
                      policy.insuranceType.count <= 100, policy.coverage.count <= 2_000,
                      policy.cancellationTerms.count <= 1_000,
                      policy.insuredAmount.map({ $0 >= 0 }) ?? true,
                      policy.deductible.map({ $0 >= 0 }) ?? true else { throw FinanceError.invalid }
            }
        }
        for payment in state.payments {
            guard payment.cycleIndex >= 0, payment.expectedAmount > 0,
                  payment.actualAmount.map({ $0 > 0 }) ?? true,
                  payment.principalAmount.map({ $0 >= 0 }) ?? true,
                  payment.interestAmount.map({ $0 >= 0 }) ?? true,
                  Planning.isSupportedDate(payment.dueDate),
                  Planning.isSupportedDate(payment.coverageStart),
                  (payment.status == .recorded) == (payment.transactionId != nil || payment.settlementEventId != nil),
                  contracts[payment.contractId] != nil || payment.legacyDatasetId != nil
            else { throw FinanceError.invalid }
            if let contract = contracts[payment.contractId] {
                guard payment.seriesId == contract.seriesId || payment.status != .pending else { throw FinanceError.invalid }
            }
            if let transactionId = payment.transactionId {
                guard let transaction = transactions.first(where: { $0.id == transactionId })
                else { throw FinanceError.missing }
                guard transaction.type == .expense else { throw FinanceError.invalid }
            }
            if let eventId = payment.settlementEventId {
                guard state.postings.contains(where: { $0.eventId == eventId && $0.kind == .loanSettlement })
                else { throw FinanceError.missing }
            }
        }
        try validateInstallmentPlans(state)
        for asset in state.assets {
            guard !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  asset.name.count <= 100, asset.category.count <= 100, asset.memo.count <= 1_000,
                  asset.purchasePrice >= 0, asset.expectedResidual >= 0,
                  asset.expectedResidual <= asset.purchasePrice,
                  (1...1_200).contains(asset.usefulMonths),
                  Planning.isSupportedDate(asset.purchaseDate),
                  asset.saleDate.map({ $0 >= asset.purchaseDate }) ?? true,
                  (asset.saleDate == nil) == (asset.salePrice == nil),
                  asset.salePrice.map({ $0 >= 0 }) ?? true,
                  asset.purchaseTransactionId.map({ transactionIds.contains($0) }) ?? true,
                  asset.saleTransactionId.map({ transactionIds.contains($0) }) ?? true
            else { throw FinanceError.invalid }
        }
        for repair in state.repairs {
            guard assets.contains(repair.assetId), repair.amount > 0,
                  repair.memo.count <= 1_000, Planning.isSupportedDate(repair.date),
                  repair.transactionId.map({ transactionIds.contains($0) }) ?? true
            else { throw FinanceError.invalid }
        }
        for refund in state.refunds {
            guard refund.amount > 0, refund.memo.count <= 1_000,
                  Planning.isSupportedDate(refund.date),
                  transactions.contains(where: { $0.id == refund.originalTransactionId && $0.type == .expense }),
                  refund.accountId.map({ accountIds.contains($0) }) ?? true
            else { throw FinanceError.invalid }
        }
    }

    /// Rules for contracts that use the installment-plan model (`totalPayment != nil`).
    private static func validateInstallmentPlans(_ state: FinanceState) throws {
        let accounts = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0) })
        for contract in state.contracts {
            guard let total = contract.totalPayment else { continue }
            guard contract.kind == .installment,
                  let principal = contract.principal, principal > 0,
                  let cycles = contract.maximumCycles, InstallmentSchedule.cycleRange.contains(cycles),
                  total >= principal, total >= Int64(cycles),
                  let liabilityId = contract.liabilityAccountId,
                  accounts[liabilityId]?.kind.isLiability == true,
                  let payerId = contract.paymentAccountId,
                  let payer = accounts[payerId], payer.kind == .bank || payer.kind == .cash
            else { throw FinanceError.invalid }
            let purchases = state.postings.filter { $0.eventId == contract.id && $0.kind == .installmentPurchase }
            guard purchases.count == 1, purchases[0].accountId == liabilityId, purchases[0].amount == principal
            else { throw FinanceError.invalid }
            var recordedPrincipal: Int64 = 0
            for payment in state.payments where payment.contractId == contract.id {
                if payment.status == .recorded {
                    recordedPrincipal = try add(recordedPrincipal, payment.principalAmount ?? 0)
                }
                if payment.status == .pending {
                    guard let plannedPrincipal = payment.plannedPrincipal,
                          let plannedInterest = payment.plannedInterest,
                          plannedPrincipal >= 0, plannedInterest >= 0,
                          try add(plannedPrincipal, plannedInterest) == payment.expectedAmount
                    else { throw FinanceError.invalid }
                }
            }
            var released: Int64 = 0
            for posting in state.postings where posting.eventId == contract.id && posting.kind == .installmentCancellation {
                guard posting.accountId == liabilityId, posting.amount < 0 else { throw FinanceError.invalid }
                released = try add(released, -posting.amount)
            }
            guard try add(recordedPrincipal, released) <= principal else { throw FinanceError.invalid }
        }
        for posting in state.postings where posting.kind == .installmentPurchase || posting.kind == .installmentCancellation {
            guard let contract = state.contracts.first(where: { $0.id == posting.eventId }),
                  contract.totalPayment != nil
            else { throw FinanceError.missing }
        }
    }

    /// Persists occurrence IDs once. Re-running this function keeps them stable.
    public static func generatePayments(_ original: FinanceState, through end: Date) throws -> FinanceState {
        var next = original
        var indices = Dictionary(uniqueKeysWithValues: next.payments.enumerated().map { ($0.element.key, $0.offset) })
        for contract in next.contracts {
            // Installment plans materialize every payment when registered; never regenerate them.
            if contract.totalPayment != nil { continue }
            for index in 0..<10_000 {
                if let maximum = contract.maximumCycles, index >= maximum { break }
                let due = try contract.interval.date(from: contract.firstDueDate, index: index)
                if due >= end { break }
                if let finish = contract.endDate, due > finish { break }
                let coverage = try contract.interval.date(from: contract.startDate, index: index)
                if let generationStart = contract.generationStart, due < generationStart { continue }
                let key = contract.seriesId.uuidString + ":" + String(index)
                let expected = contract.maximumCycles == index + 1
                    ? (contract.finalAmount ?? contract.expectedAmount) : contract.expectedAmount
                if let position = indices[key] {
                    if next.payments[position].status == .pending && !next.payments[position].isOverridden {
                        next.payments[position].dueDate = due
                        next.payments[position].coverageStart = coverage
                        next.payments[position].expectedAmount = expected
                    }
                } else if contract.status != .ended {
                    let payment = ScheduledPayment(contractId: contract.id, seriesId: contract.seriesId,
                        cycleIndex: index, dueDate: due, coverageStart: coverage,
                        expectedAmount: expected, legacyDatasetId: contract.legacyDatasetId)
                    indices[key] = next.payments.count
                    next.payments.append(payment)
                    guard next.payments.count <= 10_000 else { throw FinanceError.invalid }
                }
            }
        }
        return next
    }

    public static func accountBalance(_ account: FinanceAccount, postings: [AccountPosting], asOf date: Date) throws -> Int64 {
        try postings.filter { $0.accountId == account.id && $0.date >= account.openingDate && $0.date <= date }
            .reduce(account.openingBalance) { try add($0, $1.amount) }
    }

    /// A total is divided into exact yen shares. Cumulative rounding avoids losing any yen.
    public static func allocatedYen(_ total: Int64, months: Int, index: Int) throws -> Int64 {
        guard total >= 0, months > 0, index >= 0, index < months else { throw FinanceError.invalid }
        func cumulative(_ count: Int) throws -> Int64 {
            let base = total / Int64(months)
            let remainder = total % Int64(months)
            let main = base.multipliedReportingOverflow(by: Int64(count))
            let part = remainder.multipliedReportingOverflow(by: Int64(count))
            guard !main.overflow, !part.overflow else { throw FinanceError.overflow }
            return try add(main.partialValue, (part.partialValue + Int64(months / 2)) / Int64(months))
        }
        return try add(cumulative(index + 1), -cumulative(index))
    }

    private static func monthOffset(from start: Date, to target: Date) -> Int {
        Month.calendar.dateComponents([.month], from: Month(date: start).start, to: Month(date: target).start).month ?? Int.min
    }

    private static func assetAllocated(_ asset: OwnedAsset, repairs: [AssetRepair], monthIndex: Int) throws -> Int64 {
        guard monthIndex >= 0 else { return 0 }
        var result: Int64 = 0
        if monthIndex < asset.usefulMonths {
            result = try allocatedYen(asset.purchasePrice - asset.expectedResidual,
                                      months: asset.usefulMonths, index: monthIndex)
        }
        for repair in repairs where repair.assetId == asset.id {
            let start = monthOffset(from: asset.purchaseDate, to: repair.date)
            let remaining = max(1, asset.usefulMonths - start)
            let index = monthIndex - start
            if index >= 0 && index < remaining {
                result = try add(result, allocatedYen(repair.amount, months: remaining, index: index))
            }
        }
        return result
    }

    public static func effectiveMonth(_ state: FinanceState, month: Month) throws -> EffectiveMonth {
        let contractById = Dictionary(uniqueKeysWithValues: state.contracts.map { ($0.id, $0) })
        var contractTotal: Int64 = 0
        for payment in state.payments where payment.status == .pending || payment.status == .recorded {
            guard let contract = contractById[payment.contractId] else { continue }
            let amount = payment.actualAmount ?? payment.expectedAmount
            let value: Int64
            if contract.totalPayment != nil {
                let interest = payment.status == .recorded ? (payment.interestAmount ?? 0) : (payment.plannedInterest ?? 0)
                value = Month(date: payment.dueDate) == month ? interest : 0
            } else if contract.kind == .loan || contract.kind == .installment {
                value = Month(date: payment.dueDate) == month ? (payment.interestAmount ?? 0) : 0
            } else if let months = contract.interval.coverageMonths {
                let index = monthOffset(from: payment.coverageStart, to: month.start)
                value = (0..<months).contains(index) ? try allocatedYen(amount, months: months, index: index) : 0
            } else {
                value = Month(date: payment.dueDate) == month ? amount : 0
            }
            contractTotal = try add(contractTotal, value)
        }

        var assetTotal: Int64 = 0
        for asset in state.assets {
            let index = monthOffset(from: asset.purchaseDate, to: month.start)
            guard index >= 0 else { continue }
            if let sale = asset.saleDate {
                let saleIndex = monthOffset(from: asset.purchaseDate, to: sale)
                if index > saleIndex { continue }
                if index == saleIndex {
                    var total = try add(asset.purchasePrice, -(asset.salePrice ?? 0))
                    for repair in state.repairs where repair.assetId == asset.id && repair.date <= sale {
                        total = try add(total, repair.amount)
                    }
                    var previouslyAllocated: Int64 = 0
                    for past in 0..<saleIndex {
                        previouslyAllocated = try add(previouslyAllocated,
                            assetAllocated(asset, repairs: state.repairs, monthIndex: past))
                    }
                    assetTotal = try add(assetTotal, try add(total, -previouslyAllocated))
                    continue
                }
            }
            assetTotal = try add(assetTotal, assetAllocated(asset, repairs: state.repairs, monthIndex: index))
        }
        _ = try add(contractTotal, assetTotal)
        return EffectiveMonth(contracts: contractTotal, assets: assetTotal)
    }
}
