import Foundation
import SwiftData
import PersonalKakeiboDomain

extension Store {
    func widgetAccounts() throws -> [FinanceAccount] {
        try access { try readWidgetFinance().accounts }
    }

    private func readWidgetFinance() throws -> FinanceState {
        let rows = try context.fetch(FetchDescriptor<StoredFinanceState>())
        guard rows.count <= 1 else { throw StoreError.conflict }
        return try rows.first?.value() ?? FinanceState()
    }

    private func widgetTransaction(id: UUID) throws -> Transaction? {
        let rows = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { $0.id == id }))
        guard rows.count <= 1 else { throw StoreError.conflict }
        guard let row = rows.first else { return nil }
        var transaction = try row.value()
        let flags = try context.fetch(FetchDescriptor<StoredSavingsFlag>(predicate: #Predicate { $0.transactionId == id }))
        guard flags.count <= 1 else { throw StoreError.conflict }
        transaction.isSavingsEligible = flags.first?.isSavingsEligible ?? false
        return transaction
    }

    func widgetState(deviceID: UUID, defaultCategoryID: UUID? = nil) throws -> WidgetEntryState {
        try access {
            let rows = try context.fetch(FetchDescriptor<StoredWidgetEntry>()).filter { $0.deviceID == deviceID }
            guard rows.count <= 1 else { throw StoreError.conflict }
            if let row = rows.first { return try JSONDecoder().decode(WidgetEntryState.self, from: row.payload) }
            let choices = try categories(type: .expense).filter { !$0.isArchived }
            let selected = choices.first { $0.id == defaultCategoryID } ?? choices.first
            return WidgetEntryState(categoryID: selected?.id)
        }
    }

    /// State, transaction, and account posting commit in a single SQLite transaction.
    func performWidgetAction(_ action: WidgetEntryAction, value: String, sessionID: UUID,
                             deviceID: UUID, now: Date) throws {
        try access {
            let rows = try context.fetch(FetchDescriptor<StoredWidgetEntry>()).filter { $0.deviceID == deviceID }
            guard rows.count <= 1, let row = rows.first else { throw StoreError.changed }
            var state = try JSONDecoder().decode(WidgetEntryState.self, from: row.payload)
            guard state.sessionID == sessionID else { throw StoreError.changed }
            // A stale save button can be executed again after the first commit.
            if action == .save && state.mode == .saved { return }
            guard state.mode != .saved || action == .next || action == .undo else { throw StoreError.changed }
            switch action {
            case .digit: try state.append(value)
            case .backspace: if !state.amount.isEmpty { state.amount.removeLast() }
            case .clear: state.amount = ""
            case .categories: state.mode = .categories; state.page = 0
            case .accounts: state.mode = .accounts; state.page = 0
            case .selectCategory:
                guard let id = UUID(uuidString: value),
                      try categories(type: .expense).contains(where: { $0.id == id && !$0.isArchived })
                else { throw KakeiboError.missingCategory }
                state.categoryID = id; state.mode = .keypad
            case .selectAccount:
                if value.isEmpty { state.accountID = nil }
                else {
                    guard let id = UUID(uuidString: value),
                          try readWidgetFinance().accounts.contains(where: { $0.id == id && !$0.isArchived && $0.kind != .loan })
                    else { throw FinanceError.missing }
                    state.accountID = id
                }
                state.mode = .keypad
            case .previousPage: state.page = max(0, state.page - 1)
            case .nextPage:
                let count = state.mode == .categories
                    ? try categories(type: .expense).filter { !$0.isArchived }.count
                    : try readWidgetFinance().accounts.filter { !$0.isArchived && $0.kind != .loan }.count + 1
                state.page = min(max(0, (count - 1) / 6), state.page + 1)
            case .back: state.mode = .keypad; state.page = 0
            case .next:
                guard state.mode == .saved else { throw StoreError.changed }
                state.beginNext()
            case .save:
                guard state.mode == .keypad, let categoryID = state.categoryID else { throw KakeiboError.missingCategory }
                let transaction = Transaction(id: state.sessionID, type: .expense,
                    amount: try AmountValidator.parse(state.amount), categoryId: categoryID, occurredAt: now,
                    createdAt: now, updatedAt: now)
                try AmountValidator.validate(transaction, category: try allCategories().first { $0.id == categoryID })
                guard try widgetTransaction(id: transaction.id) == nil else { throw StoreError.conflict }
                var finance = try readWidgetFinance()
                if let id = state.accountID {
                    guard let account = finance.accounts.first(where: { $0.id == id && !$0.isArchived && $0.kind != .loan })
                    else { throw FinanceError.missing }
                    let posting = AccountPosting(accountId: id, eventId: transaction.id, kind: .transaction,
                        date: now, amount: account.kind == .creditCard ? transaction.amount : -transaction.amount)
                    finance.postings.append(posting); state.savedPosting = posting
                }
                context.insert(StoredTransaction(transaction))
                try writeWidgetFinance(finance)
                state.savedTransaction = transaction; state.mode = .saved
            case .undo:
                guard state.mode == .saved, let transaction = state.savedTransaction,
                      try widgetTransaction(id: transaction.id) == transaction else { throw StoreError.changed }
                var finance = try readWidgetFinance()
                guard !finance.payments.contains(where: { $0.transactionId == transaction.id }),
                      !finance.refunds.contains(where: { $0.originalTransactionId == transaction.id }),
                      !finance.assets.contains(where: { $0.purchaseTransactionId == transaction.id || $0.saleTransactionId == transaction.id }),
                      !finance.repairs.contains(where: { $0.transactionId == transaction.id })
                else { throw StoreError.conflict }
                let postings = finance.postings.filter { $0.eventId == transaction.id }
                guard postings == (state.savedPosting.map({ [$0] }) ?? []) else { throw StoreError.changed }
                finance.postings.removeAll { $0.eventId == transaction.id }
                let id = transaction.id
                let transactions = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { $0.id == id }))
                guard transactions.count == 1 else { throw StoreError.conflict }
                context.delete(transactions[0])
                for flag in try context.fetch(FetchDescriptor<StoredSavingsFlag>(predicate: #Predicate { $0.transactionId == id })) {
                    context.delete(flag)
                }
                try writeWidgetFinance(finance)
                state.cancelledSessionID = sessionID
                state.beginNext(keepingAmount: true)
            }
            do {
                row.payload = try JSONEncoder().encode(state)
                try beforeSave(); try context.save()
            } catch { context.rollback(); throw error }
        }
    }

    func initializeWidgetState(deviceID: UUID, defaultCategoryID: UUID?) throws -> WidgetEntryState {
        try access {
            let rows = try context.fetch(FetchDescriptor<StoredWidgetEntry>()).filter { $0.deviceID == deviceID }
            if !rows.isEmpty { return try widgetState(deviceID: deviceID) }
            let state = try widgetState(deviceID: deviceID, defaultCategoryID: defaultCategoryID)
            try commit { context.insert(try StoredWidgetEntry(deviceID: deviceID, state: state)) }
            return state
        }
    }

    private func writeWidgetFinance(_ finance: FinanceState) throws {
        let rows = try context.fetch(FetchDescriptor<StoredFinanceState>())
        guard rows.count <= 1 else { throw StoreError.conflict }
        if let row = rows.first { row.payload = try JSONEncoder().encode(finance) }
        else { context.insert(try StoredFinanceState(finance)) }
    }
}
