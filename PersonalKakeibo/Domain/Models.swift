import Foundation

public enum TransactionType: String, Codable, Sendable { case income, expense }
public enum TransactionSource: String, Codable, Sendable { case manual, receipt, recurring, lifecost }

public struct Transaction: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var type: TransactionType
    public var amount: Int64
    public var categoryId: UUID
    public var occurredAt: Date
    public var memo: String
    public var source: TransactionSource
    public var isSavingsEligible: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), type: TransactionType, amount: Int64, categoryId: UUID,
                occurredAt: Date, memo: String = "", source: TransactionSource = .manual,
                createdAt: Date = Date(), updatedAt: Date = Date(), isSavingsEligible: Bool = false) {
        self.id = id; self.type = type; self.amount = amount; self.categoryId = categoryId
        self.occurredAt = occurredAt; self.memo = memo; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.isSavingsEligible = isSavingsEligible
    }
    private enum CodingKeys: String, CodingKey { case id, type, amount, categoryId, occurredAt, memo, source, createdAt, updatedAt, isSavingsEligible }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); type = try c.decode(TransactionType.self, forKey: .type)
        amount = try c.decode(Int64.self, forKey: .amount); categoryId = try c.decode(UUID.self, forKey: .categoryId)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt); memo = try c.decode(String.self, forKey: .memo)
        source = try c.decode(TransactionSource.self, forKey: .source); createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isSavingsEligible = try c.decodeIfPresent(Bool.self, forKey: .isSavingsEligible) ?? false
    }

}

public struct Category: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let type: TransactionType
    public var sortOrder: Int
    public var isArchived: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, type: TransactionType, sortOrder: Int = 0,
                isArchived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.type = type; self.sortOrder = sortOrder
        self.isArchived = isArchived; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct Budget: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var monthKey: String
    public var amount: Int64
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), monthKey: String, amount: Int64,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.monthKey = monthKey; self.amount = amount
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum KakeiboError: Error, Equatable, LocalizedError {
    case invalidAmount, missingCategory, categoryTypeMismatch, archivedCategory
    case invalidCategoryName, invalidMemo, overflow, notFound, duplicateID, invalidMonth

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "金額は1以上の整数で入力してください。"
        case .missingCategory: "カテゴリが見つかりません。選び直してください。"
        case .categoryTypeMismatch: "収支区分に合うカテゴリを選んでください。"
        case .archivedCategory: "アーカイブ済みのカテゴリは新規入力に使えません。"
        case .invalidCategoryName: "カテゴリ名は1〜40文字で入力してください。"
        case .invalidMemo: "メモは1,000文字以内で入力してください。"
        case .overflow: "金額の合計が計算できる範囲を超えています。"
        case .notFound: "対象のデータが見つかりません。再読み込みしてください。"
        case .duplicateID: "同じIDのデータが複数あります。"
        case .invalidMonth: "正しい年月を指定してください。"
        }
    }
}
