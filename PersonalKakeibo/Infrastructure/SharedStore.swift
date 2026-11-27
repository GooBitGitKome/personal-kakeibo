import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif
import PersonalKakeiboDomain
import PersonalKakeiboApplication

struct SharedStoreReady: Codable {
    var deviceID: UUID
    var cloudContainer: String?
}

enum SharedStoreError: LocalizedError {
    case unavailable, needsPreparation, inconsistent
    var errorDescription: String? {
        switch self {
        case .unavailable: "共有保存領域を開けません。アプリの署名設定を確認してください。"
        case .needsPreparation: "最初に家計簿アプリを一度開いて、Widgetの準備を完了してください。"
        case .inconsistent: "共有データの準備を完了できませんでした。元のデータは保持しています。"
        }
    }
}

@MainActor enum SharedStore {
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "KakeiboAppGroup") as? String
            ?? "group.com.example.PersonalKakeibo.shared"
    }
    static func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw SharedStoreError.unavailable
        }
        let root = url.appendingPathComponent("Kakeibo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func open(isWidget: Bool) throws -> (store: Store, ready: SharedStoreReady) {
        let root = try directory()
        let legacy = ModelConfiguration(schema: Schema(versionedSchema: KakeiboSchemaV4.self),
                                        groupContainer: .none, cloudKitDatabase: .none).url
        let cloud = Bundle.main.object(forInfoDictionaryKey: "KakeiboCloudContainer") as? String
        return try open(root: root, legacyURL: legacy, isWidget: isWidget, cloud: cloud)
    }

    // Explicit URLs make the migration testable without an App Group entitlement.
    static func open(root: URL, legacyURL: URL, isWidget: Bool,
                     cloud: String? = nil, beforeReady: () throws -> Void = {}) throws -> (store: Store, ready: SharedStoreReady) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("store.lock")
        let url = root.appendingPathComponent("shared.store")
        let marker = root.appendingPathComponent("ready.json")
        return try SharedStoreLock.withLock(at: lock) {
            let ready: SharedStoreReady
            let prepared = FileManager.default.fileExists(atPath: marker.path)
            if prepared {
                ready = try JSONDecoder().decode(SharedStoreReady.self, from: Data(contentsOf: marker))
                guard FileManager.default.fileExists(atPath: url.path) else { throw SharedStoreError.inconsistent }
                if !isWidget && cloud != ready.cloudContainer { throw SharedStoreError.inconsistent }
            } else {
                guard !isWidget else { throw SharedStoreError.needsPreparation }
                ready = SharedStoreReady(deviceID: UUID(), cloudContainer: cloud)
            }
            let schema = Schema(versionedSchema: KakeiboSchema.self)
            let configuration = ModelConfiguration(schema: schema, url: url,
                cloudKitDatabase: ready.cloudContainer.map { .private($0) } ?? .none)
            let container = try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self,
                                               configurations: configuration)
            if !prepared {
                // Do not publish the shared store to extensions until all data is copied and verified.
                let destination = Store(container: container)
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    let oldSchema = Schema(versionedSchema: KakeiboSchemaV4.self)
                    let oldConfiguration = ModelConfiguration(schema: oldSchema, url: legacyURL, cloudKitDatabase: .none)
                    let oldContainer = try ModelContainer(for: oldSchema, migrationPlan: KakeiboLegacyMigrationPlan.self,
                                                         configurations: oldConfiguration)
                    let original = try Store(container: oldContainer).snapshot()
                    let current = try destination.snapshot()
                    if !BackupFormat.equivalent(current, original) {
                        guard current == BackupSnapshot(transactions: [], categories: [], budgets: []) else {
                            throw SharedStoreError.inconsistent
                        }
                        try destination.apply(original, expecting: current)
                    }
                    guard BackupFormat.equivalent(try destination.snapshot(), original) else {
                        throw SharedStoreError.inconsistent
                    }
                } else { try destination.seed() }
                try beforeReady()
                try JSONEncoder().encode(ready).write(to: marker, options: .atomic)
            }
            return (Store(container: container, lockURL: lock), ready)
        }
    }

    static func reloadWidgets() {
        guard Bundle.main.object(forInfoDictionaryKey: "KakeiboAppGroup") != nil else { return }
        let defaults = UserDefaults(suiteName: groupID)
        defaults?.set(UserDefaults.standard.string(forKey: "defaultExpense"), forKey: "defaultExpense")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "KakeiboEntryWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "KakeiboInlineEntryWidget")
        #endif
    }
}

struct WidgetEntrySnapshot: Sendable {
    var state: WidgetEntryState
    var categories: [PersonalKakeiboDomain.Category]
    var accounts: [FinanceAccount]
    var error: String?

    var categoryName: String { categories.first { $0.id == state.categoryID }?.name ?? "ジャンルを選択" }
    var accountName: String {
        state.accountID == nil ? "未指定" : (accounts.first { $0.id == state.accountID }?.name ?? "支払元を選び直す")
    }
    var canSave: Bool {
        (try? AmountValidator.parse(state.amount)) != nil && categories.contains { $0.id == state.categoryID }
            && (state.accountID == nil || accounts.contains { $0.id == state.accountID })
    }
}

@MainActor enum WidgetEntryRuntime {
    private struct Failure: Codable { let sessionID: UUID; let message: String }
    static func snapshot() throws -> WidgetEntrySnapshot {
        let (store, ready) = try SharedStore.open(isWidget: true)
        let defaultID = UserDefaults(suiteName: SharedStore.groupID)?.string(forKey: "defaultExpense").flatMap(UUID.init(uuidString:))
        let state = try store.initializeWidgetState(deviceID: ready.deviceID, defaultCategoryID: defaultID)
        let categories = try store.categories(type: .expense).filter { !$0.isArchived }
        let accounts = try store.widgetAccounts().filter { !$0.isArchived && $0.kind != .loan }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        let errorURL = try SharedStore.directory().appendingPathComponent("widget-error.json")
        let failure = (try? Data(contentsOf: errorURL)).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
        return WidgetEntrySnapshot(state: state, categories: categories, accounts: accounts,
                                   error: failure?.sessionID == state.sessionID ? failure?.message : nil)
    }
    static func perform(action: WidgetEntryAction, value: String, sessionID: UUID) {
        do {
            let (store, ready) = try SharedStore.open(isWidget: true)
            try WidgetEntryUseCases(repository: store).perform(action, value: value,
                sessionID: sessionID, deviceID: ready.deviceID)
            if let root = try? SharedStore.directory() {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("widget-error.json"))
            }
        } catch {
            if let root = try? SharedStore.directory() {
                try? JSONEncoder().encode(Failure(sessionID: sessionID, message: error.localizedDescription))
                    .write(to: root.appendingPathComponent("widget-error.json"), options: .atomic)
            }
        }
    }
}
