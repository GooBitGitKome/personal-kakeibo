import SwiftUI
import Charts
import UniformTypeIdentifiers
import PersonalKakeiboDomain

struct ContentView: View {
    @Bindable var model: KakeiboViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcomeDestination: WelcomeDestination?
    var body: some View {
        Group {
            if model.shouldShowWelcome {
                FreshStartView {
                    model.completeWelcome()
                    model.selectedTab = 0
                } addContract: {
                    model.completeWelcome()
                    model.selectedTab = 3
                    welcomeDestination = .contract
                } addAsset: {
                    model.completeWelcome()
                    model.selectedTab = 3
                    welcomeDestination = .asset
                } skip: {
                    model.completeWelcome()
                }
            } else {
                TabView(selection: $model.selectedTab) {
                    NavigationStack { EntryView(model: model) }.tag(0).tabItem { Label("入力", systemImage: "plus.circle") }
                    NavigationStack { HistoryView(model: model) }.tag(1).tabItem { Label("履歴", systemImage: "list.bullet") }
                    NavigationStack { AnalyticsView(model: model) }.tag(2).tabItem { Label("ホーム", systemImage: "chart.pie") }
                    NavigationStack(path: $model.managementPath) {
                        MenuView()
                            .navigationDestination(for: ManagementDestination.self) { destination in
                                switch destination {
                                case .accounts: FinanceAccountsView(model: model)
                                case .payments: ScheduledPaymentsView(model: model)
                                case .contracts: FinanceContractsView(model: model)
                                case .assets: FinanceAssetsView(model: model)
                                case .reminders: RemindersView(model: model)
                                }
                            }
                    }.tag(3).tabItem { Label("管理", systemImage: "square.grid.2x2") }
                    NavigationStack { SettingsView(model: model) }.tag(4).tabItem { Label("設定", systemImage: "gearshape") }
                }
            }
        }
        .sheet(item: $welcomeDestination) { destination in
            switch destination {
            case .contract: ContractEditorView(model: model, existing: nil)
            case .asset: AssetEditorView(model: model, existing: nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
        .alert("操作できませんでした", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private enum WelcomeDestination: String, Identifiable {
    case contract, asset
    var id: String { rawValue }
}

private struct FreshStartView: View {
    let record: () -> Void
    let addContract: () -> Void
    let addAsset: () -> Void
    let skip: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "square.and.pencil").font(.largeTitle)
                        .accessibilityHidden(true)
                    Text("新しい家計簿を始める").font(.largeTitle.bold())
                    Text("最初に記録したいものを選んでください。後から管理画面でも追加できます。")
                        .foregroundStyle(.secondary)
                    Button("収支を記録する", action: record)
                        .buttonStyle(.borderedProminent)
                    Button("サブスクリプションを追加", action: addContract)
                        .buttonStyle(.bordered)
                    Button("所有物を追加", action: addAsset)
                        .buttonStyle(.bordered)
                    Button("後で始める", action: skip)
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("はじめに")
        }
    }
}
struct MonthControl: View {
    let model: KakeiboViewModel
    @State private var choosingMonth = false
    @State private var selectedDate = Date()
    var body: some View {
        HStack {
            Button { model.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("前の月")
            Spacer()
            Button {
                selectedDate = model.month.start
                choosingMonth = true
            } label: {
                Text(model.month.key).font(.headline).frame(minHeight: 44)
            }.accessibilityLabel("年月を選択、" + model.month.key)
            Spacer()
            Button { model.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("次の月")
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $choosingMonth) {
            NavigationStack {
                VStack {
                    TransactionCalendar(date: $selectedDate, recordedDates: [], selectsVisibleMonth: true)
                    Text("カレンダーの年月を押すと、年と月を選択できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding()
                .navigationTitle("年月を選択")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { choosingMonth = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { model.selectMonth(selectedDate); choosingMonth = false }
                    }
                }
            }.presentationDetents([.large])
        }
    }
}
struct EntryView: View {
    @Bindable var model: KakeiboViewModel
    @FocusState private var memoFocused: Bool
    private var saveDisabled: Bool {
        model.isSaving || model.amount.isEmpty || model.categoryId == nil
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("収支区分", selection: $model.type) { Text("支出").tag(TransactionType.expense); Text("収入").tag(TransactionType.income) }.pickerStyle(.segmented)
                    .onChange(of: model.type) { _, _ in model.selectDefaultCategory() }
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(model.amount.isEmpty ? "0円" : model.amount + "円").font(.largeTitle).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).minimumScaleFactor(0.5).accessibilityLabel("入力金額 " + (model.amount.isEmpty ? "0" : model.amount) + "円")
                        Button { model.clearAmount() } label: {
                            Image(systemName: "xmark.circle").font(.title2).frame(width: 44, height: 44)
                        }.accessibilityLabel("金額を全消去").disabled(model.amount.isEmpty)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                        ForEach(["1","2","3","4","5","6","7","8","9","00","0","⌫"], id: \.self) { digit in
                            Button {
                                model.message = nil
                                if digit == "⌫" { if !model.amount.isEmpty { model.amount.removeLast() } }
                                else { model.appendAmount(digit) }
                            } label: { Text(digit).font(.title2).frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(digit == "⌫" ? "1桁削除" : digit == "00" ? "ゼロを2桁入力" : digit)
                        }
                    }
                }
                if model.choices.isEmpty { Text("設定でジャンルを追加してください。") }
                else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ジャンル").font(.headline)
                        CategoryButtons(categories: model.choices, selection: $model.categoryId,
                            defaultId: model.preferences.defaultCategory(for: model.type), setDefault: model.setDefaultCategory)
                        Text("長押しで起動時の初期ジャンルに設定").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 0) {
                    RecordedDatePicker(date: $model.date, transactions: model.transactions)
                    if !model.activeAccounts.isEmpty {
                        Divider()
                        HStack {
                            Text("支払元・入金先")
                            Spacer(minLength: 8)
                            Picker("支払元・入金先", selection: $model.selectedAccountId) {
                                Text("未指定").tag(Optional<UUID>.none)
                                ForEach(model.activeAccounts) { account in
                                    Text(account.name).tag(Optional(account.id))
                                }
                            }
                            .labelsHidden()
                        }.frame(minHeight: 44)
                    }
                    Divider()
                    TextField("メモ（任意・1,000文字まで）", text: $model.memo, axis: .vertical)
                        .focused($memoFocused)
                        .padding(.vertical, 12)
                    Divider()
                    Toggle("節約可能", isOn: $model.isSavingsEligible)
                        .padding(.vertical, 8)
                        .accessibilityHint("節約できる取引として記録します。保存成功後はオフに戻ります。")
                }
                .padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }.padding().frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .dismissKeyboardOnSwipe()
        .navigationTitle("収支を入力")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Button {
                    memoFocused = false
                    model.save()
                } label: {
                    Text(model.isSaving ? "保存中…" : "保存")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(saveDisabled ? Color.secondary : Color.white)
                        .background(saveDisabled ? Color(uiColor: .tertiarySystemFill) : Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(saveDisabled)
            }
            .frame(maxWidth: 568)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
struct HistoryView: View {
    @Bindable var model: KakeiboViewModel
    @State private var filter: UUID?
    @State private var savingsOnly = false
    @State private var editing: PersonalKakeiboDomain.Transaction?
    @State private var deleting: PersonalKakeiboDomain.Transaction?
    @State private var refunding: PersonalKakeiboDomain.Transaction?
    var rows: [PersonalKakeiboDomain.Transaction] { model.monthly.filter { (filter == nil || $0.categoryId == filter) && (!savingsOnly || $0.isSavingsEligible) } }
    var body: some View {
        List {
            MonthControl(model: model)
            if let summary = model.summary { Text("当月の総支出 " + yen(summary.expense)) }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            Picker("ジャンルで絞り込み", selection: $filter) {
                Text("すべて").tag(Optional<UUID>.none)
                ForEach(model.categories) { Text($0.name + ($0.type == .income ? "（収入）" : "（支出）")).tag(Optional($0.id)) }
            }
            Toggle("節約可能な取引のみ", isOn: $savingsOnly)
            if rows.isEmpty { Text("この月の取引はありません。") }
            ForEach(rows) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((entry.type == .income ? "収入 " : "支出 ") + yen(entry.amount)).foregroundStyle(.primary)
                        Text(model.categories.first { $0.id == entry.categoryId }?.name ?? "不明なジャンル").foregroundStyle(.secondary)
                        Text(entry.occurredAt, style: .date).foregroundStyle(.secondary)
                        if let tag = model.managementTag(for: entry) {
                            Label(tag, systemImage: "tag")
                                .font(.caption).foregroundStyle(.blue)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if entry.isSavingsEligible { Label("節約可能", systemImage: "leaf").foregroundStyle(.green) }
                        if !entry.memo.isEmpty { Text(entry.memo).foregroundStyle(.secondary) }
                    }
                }.swipeActions {
                    Button("削除", role: .destructive) { deleting = entry }
                    if entry.type == .expense { Button("返金") { refunding = entry } }
                }
            }
            ForEach(model.finance.refunds.filter { model.month.range.contains($0.date) }) { refund in
                VStack(alignment: .leading) {
                    Text("返金 " + yen(refund.amount))
                    Text(refund.date, style: .date).foregroundStyle(.secondary)
                    if !refund.memo.isEmpty { Text(refund.memo).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("履歴").refreshable { model.refresh() }
            .sheet(item: $editing) { EditTransactionView(model: model, entry: $0) }
            .sheet(item: $refunding) { RefundEditorView(model: model, original: $0) }
            .confirmationDialog("取引を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("削除", role: .destructive) { if let entry = deleting { model.delete(entry.id) }; deleting = nil }
                Button("キャンセル", role: .cancel) { deleting = nil }
            } message: { if let entry = deleting { Text(yen(entry.amount) + "・" + (model.categories.first { $0.id == entry.categoryId }?.name ?? "")) } }
    }
}
private struct RefundEditorView: View {
    let model: KakeiboViewModel
    let original: PersonalKakeiboDomain.Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date()
    @State private var accountId: UUID?
    @State private var memo = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("元の支出 " + yen(original.amount))
                TextField("返金額", text: $amount).keyboardType(.numberPad)
                DatePicker("返金日", selection: $date, displayedComponents: .date)
                Picker("返金先", selection: $accountId) {
                    Text("未指定").tag(Optional<UUID>.none)
                    ForEach(model.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("メモ", text: $memo, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("返金を記録")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try model.refund(transactionId: original.id,
                                amount: AmountValidator.parse(amount), date: date,
                                accountId: accountId, memo: memo)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
struct EditTransactionView: View {
    let model: KakeiboViewModel
    let entry: PersonalKakeiboDomain.Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var category: UUID
    @State private var date: Date
    @State private var memo: String
    @State private var isSavingsEligible: Bool
    @State private var error: String?
    init(model: KakeiboViewModel, entry: PersonalKakeiboDomain.Transaction) {
        self.model = model; self.entry = entry
        _amount = State(initialValue: String(entry.amount)); _category = State(initialValue: entry.categoryId)
        _date = State(initialValue: entry.occurredAt); _memo = State(initialValue: entry.memo)
        _isSavingsEligible = State(initialValue: entry.isSavingsEligible)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(entry.type == .expense ? "支出" : "収入")
                TextField("金額", text: $amount).keyboardType(.numberPad)
                CategoryButtons(categories: model.categories.filter { $0.type == entry.type && (!$0.isArchived || $0.id == entry.categoryId) }.sorted { $0.sortOrder < $1.sortOrder }, selection: Binding(get: { Optional(category) }, set: { if let id = $0 { category = id } }))
                RecordedDatePicker(date: $date, transactions: model.transactions)
                TextField("メモ", text: $memo, axis: .vertical)
                Toggle("節約可能", isOn: $isSavingsEligible)
                if let error { Text(error).foregroundStyle(.red) }
            }.dismissKeyboardOnSwipe().navigationTitle("取引を編集").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try model.update(entry, amount: amount, category: category, date: date, memo: memo, isSavingsEligible: isSavingsEligible); dismiss() }
                    catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}
private enum HomeMode: String, CaseIterable {
    case real = "実家計簿", effective = "実質家計簿"
}

struct AnalyticsView: View {
    let model: KakeiboViewModel
    @State private var mode: HomeMode = .real
    @State private var trend: [(month: String, income: Int64, expense: Int64)] = []
    @State private var effectiveTrend: [(month: String, amount: Int64)] = []
    @State private var annual: (income: Int64, expense: Int64)?

    private var dueThisMonth: Int64? {
        try? model.pendingPayments.filter { model.month.range.contains($0.dueDate) }
            .reduce(Int64(0)) { try FinanceRules.add($0, $1.expectedAmount) }
    }
    private var normalizedContracts: Int64 {
        let decimal = model.finance.contracts.filter {
            $0.status != .ended && $0.kind != .loan && $0.kind != .installment
        }.reduce(Decimal.zero) { sum, contract in
            sum + ((try? contract.interval.monthlyEquivalent(contract.expectedAmount)) ?? .zero)
        }
        return NSDecimalNumber(decimal: decimal).int64Value
    }
    private var upcoming: [ScheduledPayment] {
        let end = model.month.shifted(12).start
        return model.pendingPayments.filter { $0.dueDate >= model.month.start && $0.dueDate < end }
    }
    var body: some View {
        List {
            MonthControl(model: model)
            Picker("表示", selection: $mode) {
                ForEach(HomeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if mode == .real {
                realContent
            } else {
                effectiveContent
            }
            upcomingContent
            deadlineContent
        }
        .navigationTitle("ホーム")
        .task(id: model.month.key + String(model.transactions.count)
              + String(model.finance.payments.count) + String(model.finance.assets.count)) {
            loadTrend()
        }
    }
    @ViewBuilder private var realContent: some View {
        if let summary = model.summary {
                    Section("当月の実収支（利用日基準）") {
                        Text("収入 " + yen(summary.income))
                        Text("支出 " + yen(summary.expense))
                        Text("収支 " + yen(summary.balance))
                        Text("未払いの支払予定 " + (dueThisMonth.map(yen) ?? "計算不可"))
                    }
                    Section("口座とカード") {
                        if model.accountBalancesIncomplete {
                            Text("口座未指定の取引があり、残高は未確定です。")
                                .foregroundStyle(.orange)
                        }
                        ForEach(model.activeAccounts) { account in
                            Text(account.name + " " + (model.balance(for: account).map(yen) ?? "計算不可"))
                        }
                    }
                    Section("カテゴリ別支出") {
                        let positive = model.categories.filter {
                            (summary.expensesByCategory[$0.id] ?? 0) > 0
                        }
                        if positive.isEmpty { Text("支出はありません。") }
                        else {
                            Chart(positive) { category in
                                SectorMark(angle: .value("支出",
                                    Double(summary.expensesByCategory[category.id] ?? 0)))
                                    .foregroundStyle(by: .value("ジャンル", category.name))
                            }.frame(height: 220).accessibilityHidden(true)
                        }
                        ForEach(model.categories.filter { summary.expensesByCategory[$0.id] != nil }) {
                            Text($0.name + " " + yen(summary.expensesByCategory[$0.id] ?? 0))
                        }
                    }
                    if let annual {
                        Section("選択年の収支") {
                            Text("収入 " + yen(annual.income))
                            Text("支出 " + yen(annual.expense))
                        }
                    }
                    Section("12か月の推移") {
                        Chart(Array(trend.enumerated()), id: \.offset) { item in
                            BarMark(x: .value("月", item.element.month),
                                    y: .value("収入", Double(item.element.income)))
                                .foregroundStyle(by: .value("区分", "収入"))
                                .position(by: .value("区分", "収入"))
                            BarMark(x: .value("月", item.element.month),
                                    y: .value("支出", Double(item.element.expense)))
                                .foregroundStyle(by: .value("区分", "支出"))
                                .position(by: .value("区分", "支出"))
                        }.frame(height: 230).accessibilityHidden(true)
                        ForEach(Array(trend.enumerated()), id: \.offset) { item in
                            Text(item.element.month + "：収入 " + yen(item.element.income)
                                 + "／支出 " + yen(item.element.expense))
                        }
                    }
        } else { Text("集計できません。エラーを確認して再読み込みしてください。") }
    }
    @ViewBuilder private var effectiveContent: some View {
        if let cost = model.effective {
                    Section("当月の実質生活コスト") {
                        Text("継続契約 " + yen(cost.contracts))
                        Text("所有物 " + yen(cost.assets))
                        Text("合計 " + yen(cost.total)).font(.headline)
                        Text("契約の比較用月額 約" + yen(normalizedContracts))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("12か月の実質コスト") {
                        Chart(Array(effectiveTrend.enumerated()), id: \.offset) { item in
                            BarMark(x: .value("月", item.element.month),
                                    y: .value("実質コスト", Double(item.element.amount)))
                        }.frame(height: 230).accessibilityHidden(true)
                        ForEach(Array(effectiveTrend.enumerated()), id: \.offset) { item in
                            Text(item.element.month + " " + yen(item.element.amount))
                        }
                    }
        } else { Text("実質コストを計算できません。") }
    }
    @ViewBuilder private var upcomingContent: some View {
            Section("これからの支払い") {
                if upcoming.isEmpty { Text("予定はありません。") }
                ForEach(upcoming.prefix(12)) { payment in
                    Text((model.contract(for: payment)?.name ?? "支払予定") + "・"
                         + payment.dueDate.formatted(date: .abbreviated, time: .omitted)
                         + "・" + yen(payment.expectedAmount))
                }
            }
    }
    @ViewBuilder private var deadlineContent: some View {
            Section("契約の期限") {
                let today = Month.calendar.startOfDay(for: Date())
                let end = Month.calendar.date(byAdding: .day, value: 30, to: today)!
                ForEach(model.finance.contracts.filter { contract in
                    contract.status != .ended &&
                    ([contract.renewalDate, contract.cancellationDeadline].compactMap { $0 }
                        .contains { $0 >= today && $0 <= end })
                }) { contract in
                    Text(contract.name + "・更新または解約期限を確認")
                }
            }
    }
    private func loadTrend() {
        do {
            trend = try (-11...0).map { offset in
                let month = model.month.shifted(offset)
                let summary = try MonthlySummary.calculate(model.transactions, in: month.range,
                    refunds: model.finance.refunds)
                return (month.key, summary.income, summary.expense)
            }
            effectiveTrend = try (-11...0).map { offset in
                let month = model.month.shifted(offset)
                return (month.key, try FinanceRules.effectiveMonth(model.finance, month: month).total)
            }
            let year = Month.calendar.component(.year, from: model.month.start)
            let january = try Month(key: String(format: "%04d-01", year))
            var income: Int64 = 0; var expense: Int64 = 0
            for offset in 0..<12 {
                let value = try MonthlySummary.calculate(model.transactions,
                    in: january.shifted(offset).range, refunds: model.finance.refunds)
                income = try FinanceRules.add(income, value.income)
                expense = try FinanceRules.add(expense, value.expense)
            }
            annual = (income, expense)
        } catch {
            trend = []; effectiveTrend = []; annual = nil
            model.error = error.localizedDescription
        }
    }
}
