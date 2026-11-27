import AppIntents
import PersonalKakeiboDomain

struct EntryWidgetIntent: AppIntent {
    static var title: LocalizedStringResource { "家計簿Widgetを操作" }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    @Parameter(title: "操作") var action: String
    @Parameter(title: "値") var value: String
    @Parameter(title: "入力ID") var sessionID: String

    init() { action = ""; value = ""; sessionID = "" }
    init(_ action: WidgetEntryAction, value: String = "", sessionID: UUID) {
        self.action = action.rawValue; self.value = value; self.sessionID = sessionID.uuidString
    }
    func perform() async throws -> some IntentResult {
        if let action = WidgetEntryAction(rawValue: action), let id = UUID(uuidString: sessionID) {
            await WidgetEntryRuntime.perform(action: action, value: value, sessionID: id)
        }
        return .result()
    }
}


/// Consumes unavailable widget controls without reading data, authenticating, or opening the app.
struct IgnoreWidgetTapIntent: AppIntent {
    static var title: LocalizedStringResource { "利用できない操作" }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    func perform() async throws -> some IntentResult { .result() }
}
