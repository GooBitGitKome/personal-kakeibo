import Foundation

public enum QuickEntryRoute {
    public static let url = URL(string: "personalkakeibo://quick-entry")!
    public static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "personalkakeibo" && url.host?.lowercased() == "quick-entry"
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && url.port == nil
    }
}
