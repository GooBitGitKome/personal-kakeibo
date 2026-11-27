import SwiftUI
import PersonalKakeiboDomain

struct QuickExpenseView: View {
    let model: KakeiboViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entry: QuickExpenseViewModel?
    @State private var startupError: String?
    @State private var choosingCategory = false
    @State private var choosingAccount = false

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    if entry.snapshot.state.mode == .saved { result(entry) }
                    else { keypad(entry) }
                } else if let startupError {
                    ContentUnavailableView {
                        Label("入力画面を開けません", systemImage: "exclamationmark.triangle")
                    } description: { Text(startupError) }
                    actions: { Button("再試行", action: prepare) }
                } else { ProgressView("準備中…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("支出を入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .task { if entry == nil { prepare() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    do { try entry?.reload() } catch { entry?.error = error.localizedDescription }
                }
            }
            .sheet(isPresented: $choosingCategory) { categoryPicker }
            .sheet(isPresented: $choosingAccount) { accountPicker }
        }
    }

    private func prepare() {
        do {
            let (_, ready) = try SharedStore.open(isWidget: false)
            entry = try QuickExpenseViewModel(store: model.store, deviceID: ready.deviceID,
                defaultCategoryID: model.preferences.defaultCategory(for: .expense)) { model.refresh() }
            startupError = nil
        } catch { startupError = error.localizedDescription }
    }

    private func keypad(_ entry: QuickExpenseViewModel) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("今日の支出").font(.subheadline).foregroundStyle(.secondary)
                    Text(Date(), format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text((entry.snapshot.state.amount.isEmpty ? "0" : entry.snapshot.state.amount) + "円")
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.3)
                    .accessibilityLabel("入力金額 " + (entry.snapshot.state.amount.isEmpty ? "0" : entry.snapshot.state.amount) + "円")
                Button { entry.perform(.clear) } label: {
                    Image(systemName: "xmark.circle").font(.title2).frame(width: 48, height: 56)
                }.accessibilityLabel("金額を全消去")
            }.frame(minHeight: 72)
            HStack(spacing: 12) {
                selection("ジャンル", entry.snapshot.categoryName) { choosingCategory = true }
                selection("支払元", entry.snapshot.accountName) { choosingAccount = true }
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<4) { row in
                    GridRow {
                        ForEach(Array(["1","2","3","4","5","6","7","8","9","00","0","⌫"][(row * 3)..<(row * 3 + 3)]), id: \.self) { key in
                            Button { entry.perform(key == "⌫" ? .backspace : .digit, value: key) } label: {
                                Text(key).font(.largeTitle.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(key == "⌫" ? "1桁削除" : key == "00" ? "ゼロを2桁入力" : key)
                                .accessibilityIdentifier("quick.key." + key)
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
            if let error = entry.error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button { entry.perform(.save) } label: {
                Text("支出を登録").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!entry.snapshot.canSave)
            .accessibilityIdentifier("quick.save")
        }
        .padding(16).frame(maxWidth: 600)
    }

    private func selection(_ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(value).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title + "：" + value)
    }

    private func result(_ entry: QuickExpenseViewModel) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("登録しました").font(.title.bold())
            Text((entry.snapshot.state.savedTransaction?.amount ?? 0).formatted(.number) + "円")
                .font(.largeTitle.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            Text(entry.snapshot.categoryName + "・" + entry.snapshot.accountName).font(.headline)
            if let error = entry.error { Text(error).foregroundStyle(.red) }
            Spacer()
            Button { entry.perform(.next) } label: {
                Text("続けて入力").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
            }.buttonStyle(.borderedProminent)
            Button { entry.perform(.undo) } label: {
                Text("取り消す").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }.buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: 600)
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(entry?.snapshot.categories ?? []) { category in
                Button(category.name) {
                    entry?.perform(.selectCategory, value: category.id.uuidString); choosingCategory = false
                }
            }.navigationTitle("ジャンルを選択")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { choosingCategory = false } } }
        }
    }
    private var accountPicker: some View {
        NavigationStack {
            List {
                Button("未指定") { entry?.perform(.selectAccount); choosingAccount = false }
                ForEach(entry?.snapshot.accounts ?? []) { account in
                    Button(account.name) {
                        entry?.perform(.selectAccount, value: account.id.uuidString); choosingAccount = false
                    }
                }
            }.navigationTitle("支払元を選択")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { choosingAccount = false } } }
        }
    }
}
