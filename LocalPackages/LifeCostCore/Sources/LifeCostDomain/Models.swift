import Foundation
import LifeCostIntegration

public enum BillingPeriod: String, Codable, CaseIterable, Sendable {
    case monthly, yearly
    public var months: Int { self == .monthly ? 1 : 12 }
    public var label: String { self == .monthly ? "毎月" : "毎年" }
}
public enum PurchaseMethod: String, Codable, CaseIterable, Sendable { case cash, installments, loan }
public struct CostAsset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var purchaseDate = PaymentDates.string(Date())
    public var price: Int64 = 0
    public var residual: Int64 = 0
    public var months = 60
    public var method = PurchaseMethod.cash
    public var paid = true
    public var archived = false
    public var memo = ""
    public init() {}
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100, price >= 0,
              residual >= 0, residual <= price, (1...1200).contains(months), memo.count <= 1000 else { throw IntegrationError.invalid }
        _ = try PaymentDates.parse(purchaseDate)
    }
    public var monthlyCost: Decimal { Decimal(price - residual) / Decimal(months) }
}
public struct CostContract: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var seriesId = UUID()
    public var name = ""
    public var category = "other"
    public var amount: Int64 = 1
    public var type = PaymentType.fixed
    public var period = BillingPeriod.monthly
    public var startDate = PaymentDates.string(Date())
    public var firstDueDate = PaymentDates.string(Date())
    public var endDate: String?
    public var generationStart: String?
    public var count = 24
    public var finalAmount: Int64?
    public var principal: Int64?
    public var autoRenew = false
    public var syncEnabled = false
    public var assetId: UUID?
    public var memo = ""
    public init() {}
    public var finite: Bool { type == .loan || type == .installment }
    public func date(index: Int) throws -> String {
        guard index >= 1, index <= 120000 else { throw IntegrationError.invalid }
        return try PaymentDates.occurrence(first: firstDueDate, monthOffset: (index - 1) * (finite ? 1 : period.months))
    }
    public func amount(index: Int) -> Int64 { finite && index == count ? (finalAmount ?? amount) : amount }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100, !category.isEmpty,
              category.count <= 100, amount > 0, memo.count <= 1000, principal.map({ $0 > 0 }) ?? true else { throw IntegrationError.invalid }
        guard try PaymentDates.parse(startDate) <= PaymentDates.parse(firstDueDate) else { throw IntegrationError.invalid }
        if let endDate { guard try PaymentDates.parse(endDate) >= PaymentDates.parse(firstDueDate) else { throw IntegrationError.invalid } }
        if let generationStart { _ = try PaymentDates.parse(generationStart) }
        if finite {
            guard (1...600).contains(count), finalAmount.map({ $0 > 0 }) ?? true, period == .monthly else { throw IntegrationError.invalid }
            _ = try date(index: count)
            _ = try CheckedMoney.sum((1...count).map { amount(index: $0) })
        }
    }
}
public struct CostOccurrence: Codable, Equatable, Identifiable, Sendable {
    public var seriesId: UUID
    public var index: Int
    public var payment: PaymentRecord
    public var exported = false
    public var overridden = false
    public var id: UUID { payment.id }
    public var key: String { seriesId.uuidString + ":" + String(index) }
    public init(seriesId: UUID, index: Int, payment: PaymentRecord) { self.seriesId = seriesId; self.index = index; self.payment = payment }
}
public struct LifeCostSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var sourceDatasetId = UUID()
    public var assets: [CostAsset] = []
    public var contracts: [CostContract] = []
    public var occurrences: [CostOccurrence] = []
    public init() {}
    public var isEmpty: Bool { assets.isEmpty && contracts.isEmpty && occurrences.isEmpty }
    public func validate() throws {
        guard schemaVersion == 1 else { throw IntegrationError.unsupported }
        guard occurrences.count <= 10000, assets.count <= 10000, contracts.count <= 10000 else { throw IntegrationError.tooLarge }
        let ids = assets.map(\.id) + contracts.map(\.id) + occurrences.map(\.id)
        guard Set(ids).count == ids.count, Set(contracts.map(\.seriesId)).count == contracts.count,
              Set(occurrences.map(\.key)).count == occurrences.count else { throw IntegrationError.duplicate }
        try assets.forEach { try $0.validate() }; try contracts.forEach { try $0.validate() }
        let assetIds = Set(assets.map(\.id)), contractIds = Set(contracts.map(\.id))
        for c in contracts { if let id = c.assetId, !assetIds.contains(id) { throw IntegrationError.invalid } }
        for o in occurrences {
            try o.payment.validate()
            guard o.index >= 1, o.index <= 120000 else { throw IntegrationError.invalid }
            if o.payment.status == .scheduled, !contractIds.contains(o.payment.sourceItemId) { throw IntegrationError.invalid }
        }
    }
}
