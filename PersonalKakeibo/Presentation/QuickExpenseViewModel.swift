import Foundation
import Observation
import PersonalKakeiboDomain
import PersonalKakeiboApplication

@MainActor @Observable final class QuickExpenseViewModel {
    private let store: Store
    private let deviceID: UUID
    private let onCommit: () -> Void
    var snapshot: WidgetEntrySnapshot
    var error: String?

    init(store: Store, deviceID: UUID, defaultCategoryID: UUID? = nil,
         onCommit: @escaping () -> Void = {}) throws {
        self.store = store; self.deviceID = deviceID; self.onCommit = onCommit
        var state = try store.initializeWidgetState(deviceID: deviceID, defaultCategoryID: defaultCategoryID)
        // Opening the entry screen begins the next entry, while an unfinished draft is retained.
        if state.mode == .saved {
            try store.performWidgetAction(.next, value: "", sessionID: state.sessionID, deviceID: deviceID, now: Date())
            state = try store.widgetState(deviceID: deviceID)
        }
        snapshot = WidgetEntrySnapshot(state: state, categories: [], accounts: [], error: nil)
        try reload()
        SharedStore.reloadWidgets()
    }

    func reload() throws {
        var state = try store.widgetState(deviceID: deviceID)
        if state.mode == .categories || state.mode == .accounts {
            try store.performWidgetAction(.back, value: "", sessionID: state.sessionID, deviceID: deviceID, now: Date())
            state = try store.widgetState(deviceID: deviceID)
        }
        snapshot = WidgetEntrySnapshot(state: state,
            categories: try store.categories(type: .expense).filter { !$0.isArchived },
            accounts: try store.widgetAccounts().filter { !$0.isArchived && $0.kind != .loan }
                .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }, error: nil)
    }

    func perform(_ action: WidgetEntryAction, value: String = "") {
        do {
            try WidgetEntryUseCases(repository: store).perform(action, value: value,
                sessionID: snapshot.state.sessionID, deviceID: deviceID)
            try reload(); error = nil
            SharedStore.reloadWidgets()
            if action == .save || action == .undo { onCommit() }
        } catch {
            let message = error.localizedDescription
            try? reload()
            self.error = message
        }
    }
}
