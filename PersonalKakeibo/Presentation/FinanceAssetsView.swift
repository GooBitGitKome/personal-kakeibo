import SwiftUI
import PersonalKakeiboDomain

struct FinanceAssetsView: View {
    let model: KakeiboViewModel
    @State private var editing: OwnedAsset?
    @State private var adding = false
    @State private var repairing: OwnedAsset?
    var body: some View {
        List {
            Section("所有物") {
                if model.finance.assets.isEmpty { Text("所有物はまだありません。") }
                ForEach(model.finance.assets.sorted { $0.name < $1.name }) { asset in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { editing = asset } label: {
                            VStack(alignment: .leading) {
                                Text(asset.name).font(.headline)
                                Text(asset.category + "・購入 " + yen(asset.purchasePrice)
                                     + "・使用予定 \(asset.usefulMonths)か月")
                                    .font(.caption).foregroundStyle(.secondary)
                                if asset.saleDate != nil {
                                    Text("売却済み").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("修理・維持費を追加") { repairing = asset }
                            .font(.caption)
                    }
                }
                Button("所有物を追加") { adding = true }
            }
            Section("修理・維持費") {
                ForEach(model.finance.repairs.sorted { $0.date > $1.date }) { repair in
                    let name = model.finance.assets.first { $0.id == repair.assetId }?.name ?? "所有物"
                    Text(name + "・" + yen(repair.amount) + "・"
                         + repair.date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Text("購入・修理・売却の実際の入出金は取引へ関連付けます。使用コストは実質家計簿だけへ配分します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("所有物")
        .sheet(item: $editing) { AssetEditorView(model: model, existing: $0) }
        .sheet(isPresented: $adding) { AssetEditorView(model: model, existing: nil) }
        .sheet(item: $repairing) { RepairEditorView(model: model, asset: $0) }
    }
}

struct AssetEditorView: View {
    let model: KakeiboViewModel
    let existing: OwnedAsset?
    @Environment(\.dismiss) private var dismiss
    @State private var value: OwnedAsset
    @State private var price: String
    @State private var residual: String
    @State private var months: String
    @State private var hasRelease: Bool
    @State private var release: Date
    @State private var hasWarranty: Bool
    @State private var warranty: Date
    @State private var hasSupport: Bool
    @State private var support: Date
    @State private var sold: Bool
    @State private var saleDate: Date
    @State private var salePrice: String
    @State private var error: String?

    init(model: KakeiboViewModel, existing: OwnedAsset?) {
        self.model = model; self.existing = existing
        let initial = existing ?? OwnedAsset(name: "", purchaseDate: Date(),
                                             purchasePrice: 0, usefulMonths: 60)
        _value = State(initialValue: initial)
        _price = State(initialValue: existing.map { String($0.purchasePrice) } ?? "")
        _residual = State(initialValue: String(existing?.expectedResidual ?? 0))
        _months = State(initialValue: String(existing?.usefulMonths ?? 60))
        _hasRelease = State(initialValue: existing?.releaseDate != nil)
        _release = State(initialValue: existing?.releaseDate ?? Date())
        _hasWarranty = State(initialValue: existing?.warrantyEnd != nil)
        _warranty = State(initialValue: existing?.warrantyEnd ?? Date())
        _hasSupport = State(initialValue: existing?.supportEnd != nil)
        _support = State(initialValue: existing?.supportEnd ?? Date())
        _sold = State(initialValue: existing?.saleDate != nil)
        _saleDate = State(initialValue: existing?.saleDate ?? Date())
        _salePrice = State(initialValue: existing?.salePrice.map(String.init) ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("所有物") {
                    TextField("名称", text: $value.name)
                    TextField("種類", text: $value.category)
                    Toggle("中古で購入", isOn: $value.isUsed)
                    DatePicker("購入日", selection: $value.purchaseDate, displayedComponents: .date)
                    TextField("購入価格", text: $price).keyboardType(.numberPad)
                    TextField("想定売却価格", text: $residual).keyboardType(.numberPad)
                    TextField("想定使用月数", text: $months).keyboardType(.numberPad)
                    Picker("購入時の支出取引", selection: $value.purchaseTransactionId) {
                        Text("関連付けない").tag(Optional<UUID>.none)
                        ForEach(model.transactions.filter { $0.type == .expense }) { transaction in
                            Text(transaction.occurredAt.formatted(date: .abbreviated, time: .omitted)
                                 + "・" + yen(transaction.amount)).tag(Optional(transaction.id))
                        }
                    }
                }
                Section("期限と売却") {
                    Toggle("発売日を設定", isOn: $hasRelease)
                    if hasRelease { DatePicker("発売日", selection: $release, displayedComponents: .date) }
                    Toggle("保証期限を設定", isOn: $hasWarranty)
                    if hasWarranty { DatePicker("保証期限", selection: $warranty, displayedComponents: .date) }
                    Toggle("サポート終了見込みを設定", isOn: $hasSupport)
                    if hasSupport { DatePicker("サポート終了", selection: $support, displayedComponents: .date) }
                    Toggle("売却済み", isOn: $sold)
                    if sold {
                        DatePicker("売却日", selection: $saleDate, displayedComponents: .date)
                        TextField("実際の売却価格", text: $salePrice).keyboardType(.numberPad)
                        Picker("売却時の入金取引", selection: $value.saleTransactionId) {
                            Text("関連付けない").tag(Optional<UUID>.none)
                            ForEach(model.transactions.filter { $0.type == .income }) { transaction in
                                Text(transaction.occurredAt.formatted(date: .abbreviated, time: .omitted)
                                     + "・" + yen(transaction.amount)).tag(Optional(transaction.id))
                            }
                        }
                    }
                }
                TextField("メモ", text: $value.memo, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "所有物を追加" : "所有物を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let purchase = Int64(price), purchase >= 0,
                                  let residual = Int64(residual), residual >= 0,
                                  let months = Int(months), (1...1_200).contains(months)
                            else { throw FinanceError.invalid }
                            value.purchasePrice = purchase
                            value.expectedResidual = residual
                            value.usefulMonths = months
                            value.releaseDate = hasRelease ? release : nil
                            value.warrantyEnd = hasWarranty ? warranty : nil
                            value.supportEnd = hasSupport ? support : nil
                            if sold {
                                guard let amount = Int64(salePrice), amount >= 0 else { throw FinanceError.invalid }
                                value.saleDate = saleDate; value.salePrice = amount
                            } else {
                                value.saleDate = nil; value.salePrice = nil
                                value.saleTransactionId = nil
                            }
                            value.updatedAt = Date()
                            try model.saveAsset(value); dismiss()
                        } catch { self.error = error.localizedDescription }
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

private struct RepairEditorView: View {
    let model: KakeiboViewModel
    let asset: OwnedAsset
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date()
    @State private var transactionId: UUID?
    @State private var memo = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(asset.name)
                TextField("修理・維持費", text: $amount).keyboardType(.numberPad)
                DatePicker("日付", selection: $date, displayedComponents: .date)
                Picker("実際の支出取引", selection: $transactionId) {
                    Text("関連付けない").tag(Optional<UUID>.none)
                    ForEach(model.transactions.filter { $0.type == .expense }) { transaction in
                        Text(transaction.occurredAt.formatted(date: .abbreviated, time: .omitted)
                             + "・" + yen(transaction.amount)).tag(Optional(transaction.id))
                    }
                }
                TextField("メモ", text: $memo, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("修理・維持費")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let value = AssetRepair(assetId: asset.id, date: date,
                                amount: try AmountValidator.parse(amount),
                                transactionId: transactionId, memo: memo)
                            try model.saveRepair(value); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
