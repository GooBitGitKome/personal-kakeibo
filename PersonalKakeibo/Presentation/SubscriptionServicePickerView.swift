import SwiftUI

struct SubscriptionServicePickerView: View {
    @Binding var name: String
    let onManualEntry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingService: SubscriptionService?
    @State private var enteringManually = false

    var body: some View {
        List {
            Section {
                Button("その他・手入力") {
                    enteringManually = true
                    dismiss()
                }
            }
            ForEach(SubscriptionServiceGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(SubscriptionService.catalog.filter { $0.group == group }) { service in
                        Button(service.name) { select(service) }
                    }
                }
            }
        }
        .navigationTitle("サービスを選ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if enteringManually { onManualEntry() }
        }
        .alert("サービス名を置き換えますか？", isPresented: Binding(
            get: { pendingService != nil },
            set: { if !$0 { pendingService = nil } }
        )) {
            Button("キャンセル", role: .cancel) { pendingService = nil }
            Button("置き換える") {
                if let service = pendingService { apply(service) }
            }
        } message: {
            if let service = pendingService {
                Text("「\(name)」を「\(service.name)」に置き換えます。他の入力内容はそのままです。")
            }
        }
    }

    private func select(_ service: SubscriptionService) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == service.name {
            apply(service)
        } else {
            pendingService = service
        }
    }

    private func apply(_ service: SubscriptionService) {
        name = service.name
        pendingService = nil
        dismiss()
    }
}

private enum SubscriptionServiceGroup: String, CaseIterable, Identifiable, Sendable {
    case video = "動画・配信"
    case music = "音楽"
    case cloud = "クラウド"
    case software = "ソフトウェア・AI"
    case membership = "会員サービス"

    var id: Self { self }
}

private struct SubscriptionService: Identifiable, Sendable {
    let id: String
    let name: String
    let group: SubscriptionServiceGroup

    static let catalog: [SubscriptionService] = [
        .init(id: "netflix", name: "Netflix", group: .video),
        .init(id: "disney-plus", name: "Disney+", group: .video),
        .init(id: "hulu", name: "Hulu", group: .video),
        .init(id: "u-next", name: "U-NEXT", group: .video),
        .init(id: "dazn", name: "DAZN", group: .video),
        .init(id: "youtube-premium", name: "YouTube Premium", group: .video),
        .init(id: "apple-music", name: "Apple Music", group: .music),
        .init(id: "spotify", name: "Spotify", group: .music),
        .init(id: "icloud-plus", name: "iCloud+", group: .cloud),
        .init(id: "google-one", name: "Google One", group: .cloud),
        .init(id: "microsoft-365", name: "Microsoft 365", group: .software),
        .init(id: "adobe-creative-cloud", name: "Adobe Creative Cloud", group: .software),
        .init(id: "chatgpt", name: "ChatGPT", group: .software),
        .init(id: "amazon-prime", name: "Amazonプライム", group: .membership)
    ]
}
