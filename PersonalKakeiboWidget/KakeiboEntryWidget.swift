import SwiftUI
@preconcurrency import WidgetKit
import AppIntents
import PersonalKakeiboDomain

struct EntryWidgetTimeline: TimelineEntry, Sendable {
    var date: Date
    var snapshot: WidgetEntrySnapshot?
    var error: String?
}

// WidgetKit's callback is pre-concurrency. Transfer ownership once and invoke only on MainActor.
private final class WidgetCompletion<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void
    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    @MainActor func call(_ value: Value) { callback(value) }
}

struct EntryWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> EntryWidgetTimeline {
        .init(date: Date(), snapshot: Self.preview, error: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (EntryWidgetTimeline) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let callback = WidgetCompletion(completion)
        Task { @MainActor in callback.call(Self.load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EntryWidgetTimeline>) -> Void) {
        let callback = WidgetCompletion(completion)
        Task { @MainActor in
            let entry = Self.load()
            callback.call(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        }
    }
    @MainActor private static func load() -> EntryWidgetTimeline {
        do { return .init(date: Date(), snapshot: try WidgetEntryRuntime.snapshot(), error: nil) }
        catch { return .init(date: Date(), snapshot: nil, error: error.localizedDescription) }
    }
    private static var preview: WidgetEntrySnapshot {
        let category = PersonalKakeiboDomain.Category(name: "食費", type: .expense)
        return .init(state: WidgetEntryState(categoryID: category.id), categories: [category], accounts: [], error: nil)
    }
}

struct EntryWidgetView: View {
    let entry: EntryWidgetTimeline
    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                WidgetEntryPanel(snapshot: snapshot)
            } else {
                VStack(spacing: 12) {
                    Label("支出を登録", systemImage: "square.and.pencil").font(.headline)
                    Text(entry.error ?? "データを読み込めませんでした。")
                        .font(.subheadline).multilineTextAlignment(.center)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
        .privacySensitive()
    }
}

struct WidgetEntryPanel: View {
    let snapshot: WidgetEntrySnapshot
    private var state: WidgetEntryState { snapshot.state }
    var body: some View {
        VStack(spacing: 5) {
            if state.mode == .saved { result }
            else if state.mode == .categories || state.mode == .accounts { choices }
            else { keypad }
            if let error = snapshot.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
                    .accessibilityLabel("操作できませんでした。" + error)
            }
        }
        .invalidatableContent()
    }

    private func action(_ title: String, _ action: WidgetEntryAction, value: String = "",
                        prominent: Bool = false, available: Bool = true) -> some View {
        // Disabled controls can fall through to WidgetKit's app link.
        // Keep an intent-backed button even when unavailable, and consume the tap with a no-op.
        Group {
            if available {
                Button(intent: EntryWidgetIntent(action, value: value, sessionID: state.sessionID)) {
                    actionLabel(title, prominent: prominent, available: true)
                }
            } else {
                Button(intent: IgnoreWidgetTapIntent()) {
                    actionLabel(title, prominent: false, available: false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(available ? "" : "利用できません")
        .accessibilityHint(available ? "" : "現在この操作は利用できません")
    }

    private func actionLabel(_ title: String, prominent: Bool, available: Bool) -> some View {
        Text(title).font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 3)
            .foregroundStyle(available ? (prominent ? Color.white : Color.primary) : Color.secondary)
            .background(prominent ? Color.accentColor : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }

    private var keypad: some View {
        VStack(spacing: 5) {
            HStack {
                Text("支出").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text((state.amount.isEmpty ? "0" : state.amount) + "円")
                    .font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityLabel("入力金額 " + (state.amount.isEmpty ? "0" : state.amount) + "円")
                Button(intent: EntryWidgetIntent(.clear, sessionID: state.sessionID)) {
                    Image(systemName: "xmark.circle").frame(width: 32, height: 32)
                }.buttonStyle(.plain).accessibilityLabel("金額を全消去")
            }.frame(height: 32)
            HStack(spacing: 6) {
                action("ジャンル：" + snapshot.categoryName, .categories)
                action("支払元：" + snapshot.accountName, .accounts)
            }.frame(height: 38)
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(0..<4) { row in
                    GridRow {
                        ForEach(Array(["1","2","3","4","5","6","7","8","9","00","0","⌫"][(row * 3)..<(row * 3 + 3)]), id: \.self) { key in
                            Button(intent: EntryWidgetIntent(key == "⌫" ? .backspace : .digit,
                                                           value: key, sessionID: state.sessionID)) {
                                Text(key).font(.title3.weight(.medium))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(key == "⌫" ? "1桁削除" : key == "00" ? "ゼロを2桁入力" : key)
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
            action("今日の支出を登録", .save, prominent: snapshot.canSave, available: snapshot.canSave)
                .frame(height: 40)
        }
    }

    private var choices: some View {
        let selectingCategory = state.mode == .categories
        let items: [(id: String, title: String)] = selectingCategory
            ? snapshot.categories.map { ($0.id.uuidString, $0.name) }
            : [("", "未指定")] + snapshot.accounts.map { ($0.id.uuidString, $0.name) }
        let maxPage = max(0, (items.count - 1) / 6)
        let page = min(state.page, maxPage)
        let visible = Array(items.dropFirst(page * 6).prefix(6))
        return VStack(spacing: 8) {
            Text(selectingCategory ? "ジャンルを選択" : "支払元を選択").font(.headline)
            if visible.isEmpty {
                Text("設定で支出ジャンルを追加してください。")
                    .font(.subheadline).frame(maxHeight: .infinity)
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<3) { row in
                        GridRow {
                            ForEach(0..<2) { column in
                                let index = row * 2 + column
                                if index < visible.count {
                                    action(visible[index].title, selectingCategory ? .selectCategory : .selectAccount,
                                           value: visible[index].id)
                                } else { Color.clear }
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            HStack {
                action("前へ", .previousPage, available: page > 0)
                Text("\(page + 1)/\(maxPage + 1)").font(.caption)
                action("次へ", .nextPage, available: page < maxPage)
            }.frame(height: 40)
            action("入力に戻る", .back).frame(height: 40)
        }
    }

    private var result: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("登録しました").font(.headline)
            Text((state.savedTransaction?.amount ?? 0).formatted(.number) + "円")
                .font(.title2.bold()).monospacedDigit()
            Text(snapshot.categoryName + "・" + snapshot.accountName).font(.subheadline)
            Spacer(minLength: 0)
            action("続けて入力", .next, prominent: true).frame(height: 44)
            action("取り消す", .undo).frame(height: 44)
        }
    }
}

struct QuickEntryLauncherView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Link(destination: QuickEntryRoute.url) {
            Group {
                if family == .systemMedium {
                    HStack(spacing: 20) {
                        Image(systemName: "square.and.pencil").font(.system(size: 44)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("支出を入力").font(.title3.bold())
                            Text("タップして全画面のテンキーを開く").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: family == .systemSmall ? 10 : 20) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: family == .systemSmall ? 36 : 64)).foregroundStyle(.blue)
                        Text("支出を入力").font(family == .systemSmall ? .headline : .title.bold())
                        Text("全画面で入力").font(.subheadline).foregroundStyle(.secondary)
                        if family == .systemLarge {
                            Text("金額・ジャンル・支払元を大きな画面で指定できます。")
                                .font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("全画面で支出を入力")
        .widgetURL(QuickEntryRoute.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct KakeiboEntryWidget: Widget {
    let kind = "KakeiboEntryWidget"
    var body: some WidgetConfiguration {
        #if KAKEIBO_INLINE_WIDGET_TESTING
        // Exercise the production inline panel in a stable, already-installed simulator slot.
        StaticConfiguration(kind: kind, provider: EntryWidgetProvider()) { EntryWidgetView(entry: $0) }
            .configurationDisplayName("Widget内で支出を登録")
            .supportedFamilies([.systemLarge])
        #else
        StaticConfiguration(kind: kind, provider: EntryWidgetProvider()) { _ in QuickEntryLauncherView() }
            .configurationDisplayName("全画面で支出を入力")
            .description("タップすると大きなテンキーの入力画面を直接開きます。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

struct KakeiboInlineEntryWidget: Widget {
    let kind = "KakeiboInlineEntryWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EntryWidgetProvider()) { EntryWidgetView(entry: $0) }
            .configurationDisplayName("Widget内で支出を登録")
            .description("以前のテンキーWidget。アプリを開かずに登録します。")
            .supportedFamilies([.systemLarge])
    }
}

@main struct KakeiboWidgetBundle: WidgetBundle {
    var body: some Widget {
        KakeiboEntryWidget()
        KakeiboInlineEntryWidget()
    }
}
