import Foundation
import PersonalKakeiboDomain
import PersonalKakeiboApplication

extension KakeiboViewModel {
    var currentMonthSubscriptions: [ScheduledPayment] {
        let ids = Set(finance.contracts.filter { $0.kind == .subscription && $0.status != .ended }.map(\.id))
        return pendingPayments.filter { ids.contains($0.contractId) && Month().range.contains($0.dueDate) }
    }
    func recordSubscriptions(_ payments: [ScheduledPayment]) throws {
        try FinanceUseCases(repository: store).recordSubscriptions(payments, month: Month())
        refresh(); requestNotifications()
    }
    func managementTag(for transaction: Transaction) -> String? {
        if let payment = finance.payments.first(where: { $0.transactionId == transaction.id }),
           let contract = contract(for: payment) {
            let kind = contract.kind == .subscription ? "サブスク" : contract.kind.label
            return "管理・" + kind + "：" + contract.name
        }
        if let asset = finance.assets.first(where: {
            $0.purchaseTransactionId == transaction.id || $0.saleTransactionId == transaction.id
        }) { return "管理・所有物：" + asset.name }
        if let repair = finance.repairs.first(where: { $0.transactionId == transaction.id }),
           let asset = finance.assets.first(where: { $0.id == repair.assetId }) {
            return "管理・修理：" + asset.name
        }
        return transaction.source == .lifecost ? "管理" : nil
    }
    var activeAccounts: [FinanceAccount] {
        finance.accounts.filter { !$0.isArchived }.sorted { $0.name < $1.name }
    }
    var pendingPayments: [ScheduledPayment] {
        finance.payments.filter { $0.status == .pending }
            .sorted { ($0.dueDate, $0.id.uuidString) < ($1.dueDate, $1.id.uuidString) }
    }
    var accountBalancesIncomplete: Bool {
        guard let start = activeAccounts.map(\.openingDate).min() else { return false }
        let assigned = Set(finance.postings.filter { $0.kind == .transaction }.map(\.eventId))
        return transactions.contains { $0.occurredAt >= start && !assigned.contains($0.id) }
    }
    func balance(for account: FinanceAccount) -> Int64? {
        try? FinanceRules.accountBalance(account, postings: finance.postings, asOf: Date())
    }
    func contract(for payment: ScheduledPayment) -> FinanceContract? {
        finance.contracts.first { $0.id == payment.contractId }
    }
    func saveAccount(_ account: FinanceAccount) throws {
        try FinanceUseCases(repository: store).saveAccount(account)
        refresh()
        if selectedAccountId == nil && !account.kind.isLiability { selectedAccountId = account.id }
    }
    func saveContract(_ contract: FinanceContract) throws {
        try FinanceUseCases(repository: store).saveContract(contract)
        refresh(); requestNotifications()
    }
    func saveAsset(_ asset: OwnedAsset) throws {
        try FinanceUseCases(repository: store).saveAsset(asset); refresh()
    }
    func saveRepair(_ repair: AssetRepair) throws {
        try FinanceUseCases(repository: store).saveRepair(repair); refresh()
    }
    func editPayment(_ payment: ScheduledPayment, amount: Int64, dueDate: Date) throws {
        try FinanceUseCases(repository: store).editPayment(payment, amount: amount, dueDate: dueDate)
        refresh()
    }
    func skipPayment(_ payment: ScheduledPayment) throws {
        try FinanceUseCases(repository: store).skipPayment(payment); refresh()
    }
    func recordPayment(_ payment: ScheduledPayment, amount: Int64, categoryId: UUID,
                       date: Date, accountId: UUID?, principal: Int64?, memo: String) throws {
        try FinanceUseCases(repository: store).recordPayment(payment, amount: amount,
            categoryId: categoryId, date: date, accountId: accountId, principal: principal,
            memo: memo)
        refresh()
    }
    func transfer(amount: Int64, from source: UUID, to destination: UUID, date: Date) throws {
        try FinanceUseCases(repository: store).transfer(amount: amount, from: source,
            to: destination, date: date)
        refresh()
    }
    func settleCard(amount: Int64, card: UUID, bank: UUID, date: Date) throws {
        try FinanceUseCases(repository: store).settleCard(amount: amount, cardId: card,
            bankId: bank, date: date)
        refresh()
    }
    func refund(transactionId: UUID, amount: Int64, date: Date,
                accountId: UUID?, memo: String) throws {
        try FinanceUseCases(repository: store).refund(originalTransactionId: transactionId,
            amount: amount, date: date, accountId: accountId, memo: memo)
        refresh()
    }
    func installmentStatus(for contract: FinanceContract) -> InstallmentStatus? {
        try? finance.installmentStatus(for: contract.id)
    }
    func suggestedSplit(for payment: ScheduledPayment, amount: Int64) -> (principal: Int64, interest: Int64)? {
        try? finance.suggestedSplit(for: payment, amount: amount)
    }
    func registerInstallment(_ input: FinanceUseCases.InstallmentInput) throws {
        try FinanceUseCases(repository: store).registerInstallment(input)
        refresh(); requestNotifications()
    }
    func cancelInstallment(_ contractId: UUID, date: Date, expectedPendingCount: Int,
                           expectedRemainingPrincipal: Int64) throws {
        try FinanceUseCases(repository: store).cancelInstallment(contractId, date: date,
            expectedPendingCount: expectedPendingCount, expectedRemainingPrincipal: expectedRemainingPrincipal)
        refresh(); requestNotifications()
    }
    func prepayInstallment(_ contractId: UUID, date: Date, fee: Int64, expectedPendingCount: Int,
                           expectedRemainingPrincipal: Int64) throws {
        try FinanceUseCases(repository: store).prepayInstallment(contractId, date: date, fee: fee,
            expectedPendingCount: expectedPendingCount, expectedRemainingPrincipal: expectedRemainingPrincipal)
        refresh(); requestNotifications()
    }
    func changeInstallmentTerms(_ contractId: UUID, remainingTotal: Int64, remainingCycles: Int,
                                expectedPendingCount: Int, expectedRemainingPrincipal: Int64) throws {
        try FinanceUseCases(repository: store).changeInstallmentTerms(contractId,
            remainingTotal: remainingTotal, remainingCycles: remainingCycles,
            expectedPendingCount: expectedPendingCount, expectedRemainingPrincipal: expectedRemainingPrincipal)
        refresh(); requestNotifications()
    }
}
