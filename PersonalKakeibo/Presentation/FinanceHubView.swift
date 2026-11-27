import SwiftUI
import PersonalKakeiboDomain

struct MenuView: View {
    var body: some View {
        List {
            Section("家計を管理") {
                NavigationLink("口座・カード・振替", value: ManagementDestination.accounts)
                NavigationLink("支払予定", value: ManagementDestination.payments)
            }
            Section("生活コストを管理") {
                NavigationLink("契約・サブスクリプション・保険", value: ManagementDestination.contracts)
                NavigationLink("所有物・修理費", value: ManagementDestination.assets)
            }
            Section("予定と通知") {
                NavigationLink("リマインダー", value: ManagementDestination.reminders)
            }
        }
        .navigationTitle("管理")
    }
}

struct FinanceAccountsView: View {
    let model: KakeiboViewModel
    @State private var editing: FinanceAccount?
    @State private var adding = false
    @State private var action: AccountMoneyAction?
    var body: some View {
        List {
            if model.accountBalancesIncomplete {
                Text("開始日以降に口座未指定の取引があります。残高は未確定です。")
                    .foregroundStyle(.orange)
            }
            Section("口座と開始残高") {
                ForEach(model.finance.accounts) { account in
                    Button { editing = account } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.name)
                                Text(account.kind.label + (account.isArchived ? "・アーカイブ済み" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.balance(for: account).map(yen) ?? "計算不可")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                Button("口座を追加") { adding = true }
            }
            Section("残高を動かす") {
                Button("口座間振替") { action = .transfer }
                Button("カード引落を記録") { action = .cardSettlement }
                Text("振替とカード引落は収入・支出へ再計上しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("口座・カード")
        .sheet(item: $editing) { AccountEditorView(model: model, existing: $0) }
        .sheet(isPresented: $adding) { AccountEditorView(model: model, existing: nil) }
        .sheet(item: $action) { AccountMoneyActionView(model: model, action: $0) }
    }
}

private struct AccountEditorView: View {
    let model: KakeiboViewModel
    let existing: FinanceAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: AccountKind
    @State private var openingDate: Date
    @State private var balance: String
    @State private var archived: Bool
    @State private var error: String?

    init(model: KakeiboViewModel, existing: FinanceAccount?) {
        self.model = model; self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: existing?.kind ?? .cash)
        _openingDate = State(initialValue: existing?.openingDate ?? Date())
        _balance = State(initialValue: String(existing?.openingBalance ?? 0))
        _archived = State(initialValue: existing?.isArchived ?? false)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("口座名", text: $name)
                Picker("種類", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                DatePicker("残高の開始日", selection: $openingDate, displayedComponents: .date)
                TextField(kind.isLiability ? "開始時の未払額" : "開始残高",
                          text: $balance).keyboardType(.numberPad)
                if existing != nil { Toggle("アーカイブ", isOn: $archived) }
                Text("開始日より前の取引は残高へさかのぼって加算しません。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "口座を追加" : "口座を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let amount = Int64(balance), amount >= 0 else { throw FinanceError.invalid }
                            let value = FinanceAccount(id: existing?.id ?? UUID(), name: name,
                                kind: kind, openingDate: openingDate, openingBalance: amount,
                                isArchived: archived)
                            try model.saveAccount(value); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

private enum AccountMoneyAction: String, Identifiable {
    case transfer, cardSettlement
    var id: String { rawValue }
}

private struct AccountMoneyActionView: View {
    let model: KakeiboViewModel
    let action: AccountMoneyAction
    @Environment(\.dismiss) private var dismiss
    @State private var fromId: UUID?
    @State private var toId: UUID?
    @State private var amount = ""
    @State private var date = Date()
    @State private var error: String?

    private var sources: [FinanceAccount] {
        action == .transfer
            ? model.activeAccounts.filter { !$0.kind.isLiability }
            : model.activeAccounts.filter { $0.kind == .creditCard }
    }
    private var destinations: [FinanceAccount] {
        action == .transfer
            ? model.activeAccounts.filter { !$0.kind.isLiability }
            : model.activeAccounts.filter { $0.kind == .bank || $0.kind == .cash }
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker(action == .transfer ? "振替元" : "カード", selection: $fromId) {
                    Text("選択").tag(Optional<UUID>.none)
                    ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(action == .transfer ? "振替先" : "引落口座", selection: $toId) {
                    Text("選択").tag(Optional<UUID>.none)
                    ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("金額", text: $amount).keyboardType(.numberPad)
                DatePicker("日付", selection: $date, displayedComponents: .date)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(action == .transfer ? "口座間振替" : "カード引落")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("記録") {
                        do {
                            guard let fromId, let toId else { throw FinanceError.missing }
                            let value = try AmountValidator.parse(amount)
                            if action == .transfer {
                                try model.transfer(amount: value, from: fromId, to: toId, date: date)
                            } else {
                                try model.settleCard(amount: value, card: fromId, bank: toId, date: date)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct ScheduledPaymentsView: View {
    let model: KakeiboViewModel
    @State private var recording: ScheduledPayment?
    @State private var editing: ScheduledPayment?
    @State private var skipping: ScheduledPayment?
    var body: some View {
        List {
            Section("未払いの予定") {
                if model.pendingPayments.isEmpty { Text("予定はありません。") }
                ForEach(model.pendingPayments) { payment in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.contract(for: payment)?.name ?? "支払予定").font(.headline)
                        Text(payment.dueDate.formatted(date: .abbreviated, time: .omitted)
                             + "・予定 " + yen(payment.expectedAmount))
                        HStack {
                            Button("支払いを確認") { recording = payment }
                                .buttonStyle(.borderedProminent)
                            Button("予定を編集") { editing = payment }
                            Button("スキップ") { skipping = payment }
                        }
                    }
                }
            }
            Section("処理済み") {
                ForEach(model.finance.payments.filter { $0.status != .pending }
                    .sorted { $0.dueDate > $1.dueDate }) { payment in
                    VStack(alignment: .leading) {
                        Text(model.contract(for: payment)?.name ?? "支払予定")
                        Text(payment.dueDate.formatted(date: .abbreviated, time: .omitted)
                             + "・" + payment.status.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("支払予定")
        .sheet(item: $recording) { PaymentActionView(model: model, payment: $0, recording: true) }
        .sheet(item: $editing) { PaymentActionView(model: model, payment: $0, recording: false) }
        .confirmationDialog("この予定をスキップしますか？", isPresented: Binding(
            get: { skipping != nil }, set: { if !$0 { skipping = nil } })) {
            Button("スキップ") {
                if let skipping {
                    do { try model.skipPayment(skipping) }
                    catch { model.error = error.localizedDescription }
                }
                skipping = nil
            }
            Button("キャンセル", role: .cancel) { skipping = nil }
        }
    }
}

private struct PaymentActionView: View {
    let model: KakeiboViewModel
    let payment: ScheduledPayment
    let recording: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var principal: String
    @State private var date: Date
    @State private var categoryId: UUID
    @State private var accountId: UUID?
    @State private var memo = ""
    @State private var error: String?
    private var finite: Bool {
        guard let kind = model.contract(for: payment)?.kind else { return false }
        return kind == .loan || kind == .installment
    }
    init(model: KakeiboViewModel, payment: ScheduledPayment, recording: Bool) {
        self.model = model; self.payment = payment; self.recording = recording
        _amount = State(initialValue: String(payment.expectedAmount))
        _principal = State(initialValue: String(payment.expectedAmount))
        _date = State(initialValue: recording ? Date() : payment.dueDate)
        _categoryId = State(initialValue: model.contract(for: payment)?.categoryId
            ?? model.categories.first(where: { $0.type == .expense })?.id ?? UUID())
        _accountId = State(initialValue: model.contract(for: payment)?.paymentAccountId
            ?? model.selectedAccountId)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(model.contract(for: payment)?.name ?? "支払予定")
                TextField(recording ? "実際の支払額" : "予定額", text: $amount)
                    .keyboardType(.numberPad)
                DatePicker(recording ? "支払日" : "予定日", selection: $date,
                           displayedComponents: .date)
                if recording {
                    Picker("支払元", selection: $accountId) {
                        Text("未指定").tag(Optional<UUID>.none)
                        ForEach(model.activeAccounts.filter { !$0.kind.isLiability }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                        ForEach(model.activeAccounts.filter { $0.kind == .creditCard }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                    if finite {
                        TextField("元本返済額", text: $principal).keyboardType(.numberPad)
                        Text("差額を利息として支出に計上します。借入金口座は契約で設定してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("支出カテゴリ", selection: $categoryId) {
                        ForEach(model.categories.filter { $0.type == .expense && !$0.isArchived }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    TextField("メモ", text: $memo, axis: .vertical)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(recording ? "支払いを確認" : "予定を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let value = try AmountValidator.parse(amount)
                            if recording {
                                try model.recordPayment(payment, amount: value, categoryId: categoryId,
                                    date: date, accountId: accountId,
                                    principal: finite ? Int64(principal) : nil, memo: memo)
                            } else {
                                try model.editPayment(payment, amount: value, dueDate: date)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
