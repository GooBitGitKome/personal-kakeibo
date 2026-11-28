import SwiftUI
import PersonalKakeiboDomain
import PersonalKakeiboApplication

/// Registers an installment purchase from the purchase amount, the total to pay and the cycle count.
struct InstallmentRegisterView: View {
    let model: KakeiboViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var principal = ""
    @State private var total = ""
    @State private var cycles = "12"
    @State private var purchaseDate = Date()
    @State private var firstDue = Date()
    @State private var categoryId: UUID
    @State private var paymentAccountId: UUID?
    @State private var liabilityAccountId: UUID?
    @State private var memo = ""
    @State private var registerAsset = false
    @State private var usefulMonths = "36"
    @State private var error: String?

    init(model: KakeiboViewModel) {
        self.model = model
        _categoryId = State(initialValue: model.categories.first { $0.type == .expense && !$0.isArchived }?.id ?? UUID())
        _paymentAccountId = State(initialValue: model.activeAccounts.first { $0.kind == .bank || $0.kind == .cash }?.id)
        _liabilityAccountId = State(initialValue: model.activeAccounts.first { $0.kind.isLiability }?.id)
    }

    private var payers: [FinanceAccount] { model.activeAccounts.filter { $0.kind == .bank || $0.kind == .cash } }
    private var liabilities: [FinanceAccount] { model.activeAccounts.filter { $0.kind.isLiability } }

    private var parsed: (principal: Int64, total: Int64, cycles: Int)? {
        guard let amount = try? AmountValidator.parse(principal),
              let sum = try? AmountValidator.parse(total),
              let count = Int(cycles) else { return nil }
        return (amount, sum, count)
    }

    /// Why saving is not possible yet, or nil when the input is valid.
    private var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "名前を入力してください。" }
        guard let value = parsed else { return "購入額と支払総額は、1円以上の整数で入力してください。" }
        if !(2...InstallmentSchedule.cycleRange.upperBound).contains(value.cycles) {
            return "回数は2回以上1,200回以下で入力してください。"
        }
        if value.total < value.principal { return "支払総額は購入額以上である必要があります。" }
        if value.total < Int64(value.cycles) { return "支払総額は回数以上である必要があります。" }
        if payers.isEmpty || liabilities.isEmpty { return "支払元の口座と、未払口座（借入金・カード）を先に登録してください。" }
        if paymentAccountId == nil || liabilityAccountId == nil { return "支払元と未払口座を選んでください。" }
        if registerAsset {
            guard let months = Int(usefulMonths), (1...1_200).contains(months) else {
                return "使用予定月数は1か月以上1,200か月以下で入力してください。"
            }
        }
        return nil
    }

    private var preview: [InstallmentPayment]? {
        guard problem == nil, let value = parsed else { return nil }
        return try? InstallmentSchedule.make(principal: value.principal, total: value.total, cycles: value.cycles)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("購入") {
                    TextField("名前（例: パソコン）", text: $name).accessibilityIdentifier("installment.name")
                    Picker("支出カテゴリ", selection: $categoryId) {
                        ForEach(model.categories.filter { $0.type == .expense && !$0.isArchived }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    DatePicker("購入日", selection: $purchaseDate, displayedComponents: .date)
                }
                Section("金額と回数") {
                    TextField("購入額（元本）", text: $principal).keyboardType(.numberPad)
                        .accessibilityIdentifier("installment.principal")
                    TextField("支払総額（手数料・利息を含む）", text: $total).keyboardType(.numberPad)
                        .accessibilityIdentifier("installment.total")
                    TextField("回数", text: $cycles).keyboardType(.numberPad)
                        .accessibilityIdentifier("installment.cycles")
                    DatePicker("初回支払日", selection: $firstDue, displayedComponents: .date)
                    Text("支払総額と購入額の差を手数料・利息とします。各回は切り捨てて、余りは最終回に足します。毎月払いです。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("支払条件") {
                    Picker("支払元の口座", selection: $paymentAccountId) {
                        Text("選択").tag(Optional<UUID>.none)
                        ForEach(payers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("未払口座", selection: $liabilityAccountId) {
                        Text("選択").tag(Optional<UUID>.none)
                        ForEach(liabilities) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("購入額は未払口座の残高に加わります。購入額は支出に計上せず、手数料・利息だけを支払月の費用にします。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("所有物") {
                    Toggle("購入した所有物として登録", isOn: $registerAsset)
                    if registerAsset {
                        TextField("使用予定月数", text: $usefulMonths).keyboardType(.numberPad)
                    }
                }
                Section("メモ") { TextField("メモ", text: $memo, axis: .vertical) }
                if let preview, let first = preview.first, let last = preview.last {
                    Section("支払予定") {
                        Text("\(preview.count)回・合計 \(yen(installmentTotal(preview)))")
                        Text("1回目 \(describe(first))")
                        Text("最終回 \(describe(last))")
                        Text("手数料・利息の合計 \(yen(installmentInterest(preview)))")
                    }
                    .accessibilityIdentifier("installment.preview")
                }
                if let problem {
                    Text(problem).foregroundStyle(.red).accessibilityIdentifier("installment.problem")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("分割払いを登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") { save() }
                        .disabled(problem != nil)
                        .accessibilityIdentifier("installment.save")
                }
            }
        }
    }

    private func save() {
        guard problem == nil, let value = parsed,
              let paymentAccountId, let liabilityAccountId else { return }
        let asset = registerAsset
            ? FinanceUseCases.InstallmentInput.AssetInput(usefulMonths: Int(usefulMonths) ?? 36) : nil
        let input = FinanceUseCases.InstallmentInput(name: name, categoryId: categoryId,
            principal: value.principal, totalPayment: value.total, cycles: value.cycles,
            purchaseDate: purchaseDate, firstDueDate: firstDue, paymentAccountId: paymentAccountId,
            liabilityAccountId: liabilityAccountId, memo: memo, asset: asset)
        do { try model.registerInstallment(input); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// Progress of one installment plan with cancel, prepayment and term changes.
struct InstallmentDetailView: View {
    let model: KakeiboViewModel
    let contractId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCancel = false
    @State private var sheet: InstallmentAction?
    @State private var error: String?

    private var contract: FinanceContract? { model.finance.contracts.first { $0.id == contractId } }
    private var status: InstallmentStatus? { try? model.finance.installmentStatus(for: contractId) }
    private var payments: [ScheduledPayment] {
        model.finance.payments.filter { $0.contractId == contractId }.sorted { $0.dueDate < $1.dueDate }
    }

    var body: some View {
        NavigationStack {
            List {
                if let contract, let status {
                    Section("内容") {
                        Text(contract.name).font(.headline)
                        row("購入額（元本）", yen(contract.principal ?? 0))
                        row("支払総額", yen(contract.totalPayment ?? 0))
                        if contract.status == .ended { Text("終了済み").foregroundStyle(.secondary) }
                    }
                    Section("残り") {
                        row("支払済みの回数", "\(status.paidCount)回")
                        row("残りの回数", "\(status.remainingCount)回").accessibilityIdentifier("installment.remainingCount")
                        row("残りの支払額", yen(status.remainingPayment)).accessibilityIdentifier("installment.remainingPayment")
                        row("残りの元本", yen(status.remainingPrincipal)).accessibilityIdentifier("installment.remainingPrincipal")
                    }
                    Section("操作") {
                        Button("残りの条件を変更") { sheet = .terms(status) }
                            .disabled(status.remainingCount == 0)
                        Button("一括で繰上返済") { sheet = .prepay(status) }
                            .disabled(status.remainingCount == 0 || status.remainingPrincipal <= 0)
                        Button("取消（未払いの予定をすべて取り消す）", role: .destructive) { confirmingCancel = true }
                            .disabled(status.remainingCount == 0)
                        Text("確認済みの支払は変わりません。支払いの確認は「支払予定」から行います。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("支払予定") {
                        ForEach(payments) { payment in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(payment.dueDate.formatted(date: .abbreviated, time: .omitted))
                                    Text(label(payment)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(yen(payment.actualAmount ?? payment.expectedAmount)).monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("この分割払いは見つかりません。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("分割払い")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(item: $sheet) { InstallmentActionView(model: model, contractId: contractId, action: $0) }
            .confirmationDialog("分割払いを取り消しますか？", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("取り消す", role: .destructive) { cancel() }
                Button("やめる", role: .cancel) {}
            } message: {
                if let status {
                    Text("未払いの\(status.remainingCount)回分を取り消し、未払口座から残りの元本 \(yen(status.remainingPrincipal)) を戻します。確認済みの支払は変わりません。")
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
    }

    private func label(_ payment: ScheduledPayment) -> String {
        switch payment.status {
        case .pending:
            return "予定・元本 \(yen(payment.plannedPrincipal ?? 0))・利息 \(yen(payment.plannedInterest ?? 0))"
        case .recorded:
            return "確認済み・元本 \(yen(payment.principalAmount ?? 0))・利息 \(yen(payment.interestAmount ?? 0))"
        case .cancelled: return "取消済み"
        case .skipped: return "スキップ"
        }
    }

    private func cancel() {
        guard let status else { return }
        do {
            try model.cancelInstallment(contractId, date: Date(), expectedPendingCount: status.remainingCount,
                expectedRemainingPrincipal: status.remainingPrincipal)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

enum InstallmentAction: Identifiable {
    case prepay(InstallmentStatus)
    case terms(InstallmentStatus)
    var id: String {
        switch self {
        case .prepay: return "prepay"
        case .terms: return "terms"
        }
    }
    var status: InstallmentStatus {
        switch self {
        case .prepay(let value): return value
        case .terms(let value): return value
        }
    }
}

/// Prepayment and term-change forms. Both show what will happen and ask before applying it.
struct InstallmentActionView: View {
    let model: KakeiboViewModel
    let contractId: UUID
    let action: InstallmentAction
    @Environment(\.dismiss) private var dismiss
    @State private var fee = "0"
    @State private var date = Date()
    @State private var remainingTotal = ""
    @State private var remainingCycles = ""
    @State private var confirming = false
    @State private var error: String?

    private var status: InstallmentStatus { action.status }

    private var feeValue: Int64? {
        fee.isEmpty ? 0 : Int64(fee).flatMap { $0 >= 0 ? $0 : nil }
    }

    private var termsPreview: [InstallmentPayment]? {
        guard let total = try? AmountValidator.parse(remainingTotal), let cycles = Int(remainingCycles) else { return nil }
        return try? InstallmentSchedule.make(principal: status.remainingPrincipal, total: total, cycles: cycles)
    }

    private var problem: String? {
        switch action {
        case .prepay:
            return feeValue == nil ? "手数料は0円以上の整数で入力してください。" : nil
        case .terms:
            guard let total = try? AmountValidator.parse(remainingTotal), Int(remainingCycles) != nil else {
                return "残りの支払総額と回数を入力してください。"
            }
            if total < status.remainingPrincipal { return "残りの支払総額は残りの元本以上である必要があります。" }
            if termsPreview == nil { return "回数は1回以上1,200回以下で、残りの支払総額は回数以上にしてください。" }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch action {
                case .prepay:
                    Section("繰上返済") {
                        row("残りの元本", yen(status.remainingPrincipal))
                        DatePicker("支払日", selection: $date, displayedComponents: .date)
                        TextField("手数料（任意）", text: $fee).keyboardType(.numberPad)
                        row("支払額", yen(status.remainingPrincipal + (feeValue ?? 0)))
                        Text("残りの元本は支出に計上せず、手数料だけを支出にします。未払いの予定\(status.remainingCount)回分は取り消されます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .terms:
                    Section("残りの条件") {
                        row("残りの元本", yen(status.remainingPrincipal))
                        row("現在の残りの支払額", "\(yen(status.remainingPayment))・\(status.remainingCount)回")
                        TextField("新しい残りの支払総額", text: $remainingTotal).keyboardType(.numberPad)
                        TextField("新しい残りの回数", text: $remainingCycles).keyboardType(.numberPad)
                    }
                    if let preview = termsPreview, problem == nil, let first = preview.first, let last = preview.last {
                        Section("作り直す予定") {
                            Text("\(preview.count)回・合計 \(yen(installmentTotal(preview)))")
                            Text("1回目 \(yen(first.amount))／最終回 \(yen(last.amount))")
                            Text("確認済みの支払と残りの元本は変わりません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(action.id == "prepay" ? "一括で繰上返済" : "残りの条件を変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("実行") { confirming = true }.disabled(problem != nil)
                }
            }
            .alert("実行しますか？", isPresented: $confirming) {
                Button("実行") { apply() }
                Button("やめる", role: .cancel) {}
            } message: { Text(summary) }
        }
    }

    private var summary: String {
        switch action {
        case .prepay:
            let payment = yen(status.remainingPrincipal + (feeValue ?? 0))
            let principal = yen(status.remainingPrincipal)
            let fee = yen(feeValue ?? 0)
            return "\(payment)を支払元の口座から支払い、未払口座から\(principal)を引きます。手数料は\(fee)です。"
        case .terms:
            return "未払いの\(status.remainingCount)回分を取り消し、新しい予定に作り直します。"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
    }

    private func apply() {
        do {
            switch action {
            case .prepay:
                guard let feeValue else { return }
                try model.prepayInstallment(contractId, date: date, fee: feeValue,
                    expectedPendingCount: status.remainingCount, expectedRemainingPrincipal: status.remainingPrincipal)
            case .terms:
                guard let total = try? AmountValidator.parse(remainingTotal), let cycles = Int(remainingCycles) else { return }
                try model.changeInstallmentTerms(contractId, remainingTotal: total, remainingCycles: cycles,
                    expectedPendingCount: status.remainingCount, expectedRemainingPrincipal: status.remainingPrincipal)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private func installmentTotal(_ list: [InstallmentPayment]) -> Int64 {
    list.reduce(Int64(0)) { $0 + $1.amount }
}

private func installmentInterest(_ list: [InstallmentPayment]) -> Int64 {
    list.reduce(Int64(0)) { $0 + $1.interest }
}

private func describe(_ payment: InstallmentPayment) -> String {
    let amount = yen(payment.amount)
    let principal = yen(payment.principal)
    let interest = yen(payment.interest)
    return "\(amount)（元本 \(principal)・利息 \(interest)）"
}
