import SwiftUI
import SwiftData
import UIKit
import PersonalKakeiboDomain

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    // Register before SwiftUI loads the store so cold-start notification taps are retained.
    let reminders = ReminderService()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "KakeiboCloudContainer") as? String != nil {
            application.registerForRemoteNotifications()
        }
        return true
    }
}

@main struct PersonalKakeiboApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: KakeiboViewModel?
    @State private var startupError: String?
    @State private var quickEntryPresented = false
    @State private var quickEntryToken = UUID()
    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
                        .fullScreenCover(isPresented: $quickEntryPresented, onDismiss: { model.refresh() }) {
                            QuickExpenseView(model: model).id(quickEntryToken)
                        }
                }
                else if let startupError {
                    ContentUnavailableView {
                        Label("家計簿を開けません", systemImage: "exclamationmark.triangle")
                    } description: { Text(startupError + "\n既存データは削除していません。") }
                    actions: { Button("再試行") { start() } }
                } else { ProgressView("読み込み中…").task { start() } }
            }
            .onOpenURL { url in
                if QuickEntryRoute.matches(url) {
                    quickEntryToken = UUID(); quickEntryPresented = true
                }
            }
            .environment(\.locale, Locale(identifier: "ja_JP"))
                .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
        }
    }
    @MainActor private func start() {
        do {
            let (store, _) = try SharedStore.open(isWidget: false)
            try store.seed()
            model = KakeiboViewModel(store: store, reminderService: delegate.reminders); startupError = nil
        } catch { startupError = error.localizedDescription }
    }
}
