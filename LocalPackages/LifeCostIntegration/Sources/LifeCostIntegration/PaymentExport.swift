import Foundation

public enum IntegrationError: Error, LocalizedError, Equatable {
    case invalid, unsupported, duplicate, tooLarge, unavailable, changed, overflow
    public var errorDescription: String? {
        switch self {
        case .invalid: "連携データの形式・金額・日付が不正です。"
        case .unsupported: "このデータ形式には対応していません。アプリを更新してください。"
        case .duplicate: "同じ予定のデータが重複しています。"
        case .tooLarge: "データの件数またはファイルサイズが上限を超えています。"
        case .unavailable: "連携が未設定、またはLifeCostの共有ファイルがありません。"
        case .changed: "データが変更されました。再度内容を確認してください。"
        case .overflow: "金額または改訂番号が計算可能な範囲を超えています。"
        }
    }
}

public enum PaymentDates {
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c
    }
    public static func parse(_ text: String) throws -> Date {
        guard text.utf8.count == 10, text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { throw IntegrationError.invalid }
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...9999).contains(p[0]), (1...12).contains(p[1]), (1...31).contains(p[2]),
              let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])), string(d) == text else { throw IntegrationError.invalid }
        return d
    }
    public static func string(_ date: Date) -> String {
        let p = calendar.dateComponents([.year,.month,.day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
    public static func monthStart(_ date: Date) -> Date { calendar.date(from: calendar.dateComponents([.year,.month], from: date))! }
    public static func monthRange(_ date: Date) -> Range<Date> { let start = monthStart(date); return start..<calendar.date(byAdding: .month, value: 1, to: start)! }
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    public static func timestampDate(_ value: String) throws -> Date {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$"#, options: .regularExpression) != nil else { throw IntegrationError.invalid }
        _ = try parse(String(value.prefix(10)))
        let parts = value.dropFirst(11).prefix(8).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, parts[0] < 24, parts[1] < 60, parts[2] < 60 else { throw IntegrationError.invalid }
        let f = ISO8601DateFormatter(); f.formatOptions = value.contains(".") ? [.withInternetDateTime,.withFractionalSeconds] : [.withInternetDateTime]
        guard let date = f.date(from: value) else { throw IntegrationError.invalid }; return date
    }
    /// Preserve the original anchor day after a short month or a non-leap year.
    public static func occurrence(first: String, monthOffset: Int) throws -> String {
        guard monthOffset >= 0, monthOffset <= 120000 else { throw IntegrationError.invalid }
        let start = try parse(first)
        guard let month = calendar.date(byAdding: .month, value: monthOffset, to: monthStart(start)),
              let days = calendar.range(of: .day, in: .month, for: month),
              let result = calendar.date(byAdding: .day, value: min(calendar.component(.day, from: start), days.count) - 1, to: month) else { throw IntegrationError.invalid }
        let value = string(result); _ = try parse(value); return value
    }
}

public enum PaymentStatus: String, Codable, Sendable { case scheduled, cancelled }
public enum PaymentType: String, Codable, CaseIterable, Sendable { case fixed, subscription, loan, installment }
public struct PaymentRecord: Codable, Equatable, Sendable, Identifiable {
    public var sourceItemId: UUID
    public var paymentOccurrenceId: UUID
    public var revision: Int64
    public var status: PaymentStatus
    public var updatedAt: String
    public var name: String?
    public var amount: Int64?
    public var currency: String?
    public var dueDate: String?
    public var category: String?
    public var paymentType: PaymentType?
    public var syncEnabled: Bool?
    public var id: UUID { paymentOccurrenceId }
    public init(sourceItemId: UUID, id: UUID = UUID(), revision: Int64 = 1, name: String, amount: Int64, dueDate: String, category: String, paymentType: PaymentType, now: Date = Date()) {
        self.sourceItemId = sourceItemId; paymentOccurrenceId = id; self.revision = revision; status = .scheduled
        updatedAt = PaymentDates.timestamp(now); self.name = name; self.amount = amount; currency = "JPY"
        self.dueDate = dueDate; self.category = category; self.paymentType = paymentType; syncEnabled = true
    }
    public mutating func cancel(now: Date = Date()) throws {
        guard status != .cancelled else { return }
        revision = try CheckedMoney.add(revision, 1); status = .cancelled; updatedAt = PaymentDates.timestamp(now)
        name = nil; amount = nil; currency = nil; dueDate = nil; category = nil; paymentType = nil; syncEnabled = nil
    }
    public func validate() throws {
        guard revision > 0 else { throw IntegrationError.invalid }; _ = try PaymentDates.timestampDate(updatedAt)
        if status == .scheduled {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
                  let amount, amount > 0, currency == "JPY", let dueDate, let category, !category.isEmpty, category.count <= 100,
                  paymentType != nil, syncEnabled == true else { throw IntegrationError.invalid }
            _ = try PaymentDates.parse(dueDate)
        } else {
            guard name == nil, amount == nil, currency == nil, dueDate == nil, category == nil, paymentType == nil, syncEnabled == nil else { throw IntegrationError.invalid }
        }
    }
}

public struct PaymentExport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var sourceApp = "LifeCost"
    public var sourceDatasetId: UUID
    public var exportId: UUID
    public var exportedAt: String
    public var coverageStart: String
    public var coverageEndExclusive: String
    public var payments: [PaymentRecord]
    public init(datasetId: UUID, start: String, end: String, payments: [PaymentRecord], now: Date = Date()) {
        sourceDatasetId = datasetId; exportId = UUID(); exportedAt = PaymentDates.timestamp(now)
        coverageStart = start; coverageEndExclusive = end; self.payments = payments
    }
    public func covers(_ date: Date) throws -> Bool { try PaymentDates.parse(coverageStart) <= date && date < PaymentDates.parse(coverageEndExclusive) }
    public func validate() throws {
        guard schemaVersion == 1 else { throw IntegrationError.unsupported }
        guard sourceApp == "LifeCost", payments.count <= 10000 else { throw IntegrationError.invalid }
        _ = try PaymentDates.timestampDate(exportedAt)
        let start = try PaymentDates.parse(coverageStart), end = try PaymentDates.parse(coverageEndExclusive)
        guard start < end, PaymentDates.monthStart(start) == start, PaymentDates.monthStart(end) == end else { throw IntegrationError.invalid }
        guard Set(payments.map(\.id)).count == payments.count else { throw IntegrationError.duplicate }
        try payments.forEach { try $0.validate() }
    }
}

public enum CheckedMoney {
    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 { let r = a.addingReportingOverflow(b); guard !r.overflow else { throw IntegrationError.overflow }; return r.partialValue }
    public static func sum(_ values: [Int64]) throws -> Int64 { try values.reduce(0) { try add($0,$1) } }
}
