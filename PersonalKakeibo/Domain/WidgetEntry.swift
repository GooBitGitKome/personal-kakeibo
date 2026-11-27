import Foundation

public enum WidgetEntryMode: String, Codable, Sendable {
    case keypad, categories, accounts, saved
}

public struct WidgetEntryState: Codable, Equatable, Sendable {
    public var sessionID = UUID()
    public var amount = ""
    public var categoryID: UUID?
    public var accountID: UUID?
    public var mode: WidgetEntryMode = .keypad
    public var page = 0
    public var savedTransaction: Transaction?
    public var savedPosting: AccountPosting?
    public var cancelledSessionID: UUID?

    public init(categoryID: UUID? = nil) { self.categoryID = categoryID }

    public mutating func append(_ digits: String) throws {
        guard ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "00"].contains(digits) else {
            throw KakeiboError.invalidAmount
        }
        let next = String((amount + digits).drop(while: { $0 == "0" }))
        guard next.isEmpty || Int64(next) != nil else { throw KakeiboError.invalidAmount }
        amount = next
    }

    public mutating func beginNext(keepingAmount: Bool = false) {
        sessionID = UUID()
        if !keepingAmount { amount = "" }
        mode = .keypad; page = 0
        savedTransaction = nil; savedPosting = nil
    }
}

public enum WidgetEntryAction: String, Codable, Sendable {
    case digit, backspace, clear, categories, accounts, selectCategory, selectAccount
    case previousPage, nextPage, back, save, next, undo
}

@MainActor public protocol WidgetEntryRepository {
    func performWidgetAction(_ action: WidgetEntryAction, value: String, sessionID: UUID,
                             deviceID: UUID, now: Date) throws
}
