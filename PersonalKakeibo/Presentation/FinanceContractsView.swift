import SwiftUI
import PersonalKakeiboDomain

struct FinanceContractsView: View {
    let model: KakeiboViewModel
    @State private var editing: FinanceContract?
    @State private var adding = false
    @State private var registeringInstallment = false
    @State private var detailing: FinanceContract?
    @State private var confirmingPayments: [ScheduledPayment]?

    private var groups: [(id: UUID, name: String, contracts: [FinanceContract])] {
        let grouped = Dictionary(grouping: model.finance.contracts, by: \.categoryId)
        let known = model.categories.sorted {
            ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString)
        }.compactMap { category -> (id: UUID, name: String, contracts: [FinanceContract])? in
            guard let contracts = grouped[category.id] else { return nil }
            return (category.id, category.name, contracts.sorted { $0.name < $1.name })
        }
        let knownIds = Set(model.categories.map(\.id))
        let missing = grouped.keys.filter { !knownIds.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return known + missing.map { ($0, "未分類", grouped[$0]!.sorted { $0.name < $1.name }) }
    }

    private func monthlyTotal(_ contracts: [FinanceContract]) -> String {
        guard let amount = try? FinanceRules.monthlyContractTotal(contracts) else { return "計算できません" }
        return "約" + amount.formatted(.currency(code: "JPY").precision(.fractionLength(0)))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("契約の合計（月額換算）").font(.subheadline).foregroundStyle(.secondary)
                    Text(monthlyTotal(model.finance.contracts))
                        .font(.title2.bold()).monospacedDigit()
                        .accessibilityIdentifier("contracts.monthlyTotal")
                    Text("終了済みを除く契約の予定額を月額換算。変動額を含む概算で、実際の請求額とは異なります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("契約を追加") { adding = true }
                Button("分割払いを登録") { registeringInstallment = true }
                    .accessibilityIdentifier("contracts.addInstallment")
            }
            Section("今月のサブスクリプション") {
                let payments = model.currentMonthSubscriptions
                Text("未確定 \(payments.count)件・" + payments.reduce(Decimal.zero) { $0 + Decimal($1.expectedAmount) }
                    .formatted(.currency(code: "JPY").precision(.fractionLength(0))))
                Button("今月分をまとめて確定") { confirmingPayments = payments }
                    .disabled(payments.isEmpty)
                Text("予定額を支払日付で家計簿に記帳します。変動額は確定前に支払予定で修正してください。実際の送金は行いません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.finance.contracts.isEmpty {
                Section("契約") { Text("契約はまだありません。") }
            }
            ForEach(groups, id: \.id) { group in
                Section {
                    HStack {
                        Text("月額換算の小計").foregroundStyle(.secondary)
                        Spacer()
                        Text(monthlyTotal(group.contracts)).monospacedDigit()
                    }
                    .font(.subheadline)
                    ForEach(group.contracts) { contract in
                        Button {
                            if contract.totalPayment != nil { detailing = contract } else { editing = contract }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(contract.name).font(.headline)
                                Text(contract.kind.label + "・予定 " + yen(contract.expectedAmount)
                                     + "／\(contract.interval.count)\(contract.interval.unit.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let monthly = try? contract.interval.monthlyEquivalent(contract.expectedAmount) {
                                    Text("比較用月額 約" + monthly.formatted(.currency(code: "JPY").precision(.fractionLength(0))))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let status = model.installmentStatus(for: contract) {
                                    Text("残り\(status.remainingCount)回・残りの元本 " + yen(status.remainingPrincipal))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if contract.status == .ended {
                                    Text("終了済み・合計対象外").font(.caption).foregroundStyle(.secondary)
                                } else if contract.status == .cancellationPlanned {
                                    Text("解約予定").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(group.name + "（\(group.contracts.count)件）")
                }
            }
            Section("管理") {
                NavigationLink("支払予定を確認") { ScheduledPaymentsView(model: model) }
                Text("契約の支払予定と、使用期間へ配分した生活コストは別の金額です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("契約・固定費")
        .alert("今月のサブスクをまとめて確定しますか？", isPresented: Binding(
            get: { confirmingPayments != nil }, set: { if !$0 { confirmingPayments = nil } })) {
                Button("支払いを確定") {
                    if let payments = confirmingPayments {
                        do { try model.recordSubscriptions(payments) }
                        catch { model.error = error.localizedDescription }
                    }
                    confirmingPayments = nil
                }
                Button("キャンセル", role: .cancel) { confirmingPayments = nil }
            } message: {
                if let payments = confirmingPayments {
                    Text("\(payments.count)件・" + payments.reduce(Decimal.zero) { $0 + Decimal($1.expectedAmount) }
                        .formatted(.currency(code: "JPY").precision(.fractionLength(0))) + "を記帳します。")
                }
            }
        .sheet(item: $editing) { ContractEditorView(model: model, existing: $0) }
        .sheet(isPresented: $adding) { ContractEditorView(model: model, existing: nil) }
        .sheet(isPresented: $registeringInstallment) { InstallmentRegisterView(model: model) }
        .sheet(item: $detailing) { InstallmentDetailView(model: model, contractId: $0.id) }
    }
}

struct ContractEditorView: View {
    let model: KakeiboViewModel
    let existing: FinanceContract?
    @Environment(\.dismiss) private var dismiss
    @State private var value: FinanceContract
    @State private var amount: String
    @State private var cycles: String
    @State private var finalAmount: String
    @State private var principal: String
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var hasRenewal: Bool
    @State private var renewal: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var policy: InsuranceDetails
    @State private var insuredAmount: String
    @State private var deductible: String
    @State private var hasMaturity: Bool
    @State private var maturity: Date
    @State private var hasReview: Bool
    @State private var review: Date
    @State private var error: String?
    @State private var choosingService = false
    @FocusState private var nameFocused: Bool

    init(model: KakeiboViewModel, existing: FinanceContract?) {
        self.model = model; self.existing = existing
        let defaultCategory = model.categories.first { $0.type == .expense && !$0.isArchived }?.id ?? UUID()
        let initial = existing ?? FinanceContract(name: "", kind: .subscription,
            categoryId: defaultCategory, expectedAmount: 1,
            startDate: Date(), firstDueDate: Date())
        _value = State(initialValue: initial)
        _amount = State(initialValue: existing.map { String($0.expectedAmount) } ?? "")
        _cycles = State(initialValue: existing?.maximumCycles.map(String.init) ?? "12")
        _finalAmount = State(initialValue: existing?.finalAmount.map(String.init) ?? "")
        _principal = State(initialValue: existing?.principal.map(String.init) ?? "")
        _hasEnd = State(initialValue: existing?.endDate != nil)
        _end = State(initialValue: existing?.endDate ?? Date())
        _hasRenewal = State(initialValue: existing?.renewalDate != nil)
        _renewal = State(initialValue: existing?.renewalDate ?? Date())
        _hasDeadline = State(initialValue: existing?.cancellationDeadline != nil)
        _deadline = State(initialValue: existing?.cancellationDeadline ?? Date())
        let details = existing?.insurance ?? InsuranceDetails()
        _policy = State(initialValue: details)
        _insuredAmount = State(initialValue: details.insuredAmount.map(String.init) ?? "")
        _deductible = State(initialValue: details.deductible.map(String.init) ?? "")
        _hasMaturity = State(initialValue: details.maturityDate != nil)
        _maturity = State(initialValue: details.maturityDate ?? Date())
        _hasReview = State(initialValue: details.reviewDate != nil)
        _review = State(initialValue: details.reviewDate ?? Date())
    }

    private var finite: Bool { value.kind == .loan || value.kind == .installment }
    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    Picker("種類", selection: $value.kind) {
                        ForEach(ContractKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("contract.kind")
                    if existing == nil && value.kind == .subscription {
                        Button("サービスから選ぶ") {
                            nameFocused = false
                            choosingService = true
                        }
                    }
                    TextField("サービス・契約名", text: $value.name)
                        .focused($nameFocused)
                        .accessibilityIdentifier("contract.name")
                    Picker("支出カテゴリ", selection: $value.categoryId) {
                        ForEach(model.categories.filter { $0.type == .expense && !$0.isArchived }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    .accessibilityIdentifier("contract.category")
                    TextField("予定支払額", text: $amount).keyboardType(.numberPad)
                        .accessibilityIdentifier("contract.amount")
                    Toggle("金額が毎回変わる", isOn: $value.isVariable)
                    if value.kind == .subscription {
                        Toggle("支払日に自動確定", isOn: Binding(
                            get: { value.automaticallyRecordPayment == true },
                            set: { value.automaticallyRecordPayment = $0 }))
                            .disabled(value.isVariable)
                        Text("定額のみ。アプリ起動・復帰時に、当月の支払日を迎えた未確定分を予定額で記帳します。過去月は自動確定しません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Picker("支払元", selection: $value.paymentAccountId) {
                        Text("未指定").tag(Optional<UUID>.none)
                        ForEach(model.activeAccounts.filter { $0.kind != .loan }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                    .accessibilityIdentifier("contract.paymentAccount")
                }
                Section("周期と日付") {
                    Stepper("間隔 \(value.interval.count)", value: $value.interval.count, in: 1...1200)
                        .accessibilityIdentifier("contract.intervalCount")
                    Picker("単位", selection: $value.interval.unit) {
                        ForEach(BillingUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("contract.intervalUnit")
                    DatePicker("対象期間の開始", selection: $value.startDate, displayedComponents: .date)
                        .accessibilityIdentifier("contract.startDate")
                    DatePicker("最初の支払日", selection: $value.firstDueDate, displayedComponents: .date)
                        .accessibilityIdentifier("contract.firstDueDate")
                    Toggle("終了日を設定", isOn: $hasEnd)
                    if hasEnd { DatePicker("終了日", selection: $end, displayedComponents: .date) }
                    Picker("状態", selection: $value.status) {
                        Text("利用中").tag(ContractStatus.active)
                        Text("解約予定").tag(ContractStatus.cancellationPlanned)
                        Text("終了").tag(ContractStatus.ended)
                    }
                    Toggle("自動更新", isOn: $value.autoRenew)
                    Toggle("更新日を設定", isOn: $hasRenewal)
                    if hasRenewal { DatePicker("更新日", selection: $renewal, displayedComponents: .date) }
                    Toggle("解約期限を設定", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("解約期限", selection: $deadline, displayedComponents: .date) }
                }
                if finite {
                    Section("分割・借入") {
                        TextField("支払回数", text: $cycles).keyboardType(.numberPad)
                        TextField("最終回の金額（任意）", text: $finalAmount).keyboardType(.numberPad)
                        TextField("当初元本（任意）", text: $principal).keyboardType(.numberPad)
                        Picker("未払・借入口座", selection: $value.liabilityAccountId) {
                            Text("選択").tag(Optional<UUID>.none)
                            ForEach(model.activeAccounts.filter { $0.kind.isLiability }) {
                                Text($0.name).tag(Optional($0.id))
                            }
                        }
                        Picker("購入した所有物", selection: $value.financedAssetId) {
                            Text("関連なし").tag(Optional<UUID>.none)
                            ForEach(model.finance.assets) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                if value.kind == .insurance {
                    Section("保険") {
                        TextField("保険会社", text: $policy.company)
                        TextField("商品名", text: $policy.productName)
                        TextField("保険種別", text: $policy.insuranceType)
                        TextField("補償内容", text: $policy.coverage, axis: .vertical)
                        TextField("保険金額（任意）", text: $insuredAmount).keyboardType(.numberPad)
                        TextField("免責金額（任意）", text: $deductible).keyboardType(.numberPad)
                        Toggle("満期日を設定", isOn: $hasMaturity)
                        if hasMaturity { DatePicker("満期日", selection: $maturity, displayedComponents: .date) }
                        TextField("解約条件", text: $policy.cancellationTerms, axis: .vertical)
                        Toggle("見直し日を設定", isOn: $hasReview)
                        if hasReview { DatePicker("見直し日", selection: $review, displayedComponents: .date) }
                    }
                }
                Section("見直しとメモ") {
                    TextField("必要性", text: $value.necessity)
                    TextField("利用頻度", text: $value.usageFrequency)
                    TextField("メモ", text: $value.memo, axis: .vertical)
                    Picker("既存の繰り返し収支を置き換える", selection: $value.replacedRecurringPlanId) {
                        Text("置き換えない").tag(Optional<UUID>.none)
                        ForEach(model.recurringPlans.filter { $0.type == .expense }) { plan in
                            Text(plan.memo.isEmpty ? "予定 " + yen(plan.amount) : plan.memo)
                                .tag(Optional(plan.id))
                        }
                    }
                    Text("関連付けた繰り返し収支は新しい予定と重ならないよう無効化します。記録済み取引は残ります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "契約を追加" : "契約を編集")
            .navigationDestination(isPresented: $choosingService) {
                SubscriptionServicePickerView(name: $value.name) {
                    nameFocused = true
                }
            }
            .toolbar {
                if !choosingService {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                if value.kind != .subscription || value.isVariable {
                                    value.automaticallyRecordPayment = false
                                }
                                value.expectedAmount = try AmountValidator.parse(amount)
                                value.endDate = hasEnd ? end : nil
                                value.renewalDate = hasRenewal ? renewal : nil
                                value.cancellationDeadline = hasDeadline ? deadline : nil
                                value.updatedAt = Date()
                                if finite {
                                    guard let count = Int(cycles), (1...10_000).contains(count) else { throw FinanceError.invalid }
                                    value.maximumCycles = count
                                    value.finalAmount = finalAmount.isEmpty ? nil : try AmountValidator.parse(finalAmount)
                                    value.principal = principal.isEmpty ? nil : try AmountValidator.parse(principal)
                                } else {
                                    value.maximumCycles = nil; value.finalAmount = nil
                                    value.principal = nil; value.liabilityAccountId = nil
                                    value.financedAssetId = nil
                                }
                                if value.kind == .insurance {
                                    policy.insuredAmount = insuredAmount.isEmpty ? nil : Int64(insuredAmount)
                                    policy.deductible = deductible.isEmpty ? nil : Int64(deductible)
                                    policy.maturityDate = hasMaturity ? maturity : nil
                                    policy.reviewDate = hasReview ? review : nil
                                    value.insurance = policy
                                } else { value.insurance = nil }
                                try model.saveContract(value); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .alert("保存できませんでした", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
