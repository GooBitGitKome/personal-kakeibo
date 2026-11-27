import Foundation
import LifeCostIntegration

public enum ImportedPaymentStatus: String, Codable, Sendable { case pending, recorded, dismissed, cancelled }
public struct ImportedPayment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var sourceApp = "LifeCost"
    public var sourceDatasetId: UUID
    public var source: PaymentRecord
    public var name: String
    public var amount: Int64
    public var dueDate: String
    public var categoryId: UUID
    public var status = ImportedPaymentStatus.pending
    public var transactionId: UUID?
    public var importedAt = Date()
    public var updatedAt = Date()
    public var key: String { sourceApp + ":" + sourceDatasetId.uuidString + ":" + source.id.uuidString }
    public init(datasetId: UUID, source: PaymentRecord, categoryId: UUID) throws {
        try source.validate()
        guard let name = source.name, let amount = source.amount, let dueDate = source.dueDate else { throw IntegrationError.invalid }
        sourceDatasetId = datasetId; self.source = source; self.name = name; self.amount = amount; self.dueDate = dueDate; self.categoryId = categoryId
    }
}
public struct LifeCostSetting: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var datasetId: UUID
    public var categoryMappings: [String: UUID] = [:]
    public var updatedAt = Date()
    public init(datasetId: UUID) { self.datasetId = datasetId }
}
public enum LifeCostValidation {
    public static func validate(_ snapshot: BackupSnapshot) throws {
        guard snapshot.lifeCostSettings.count <= 1,
              Set(snapshot.importedPayments.map(\.key)).count == snapshot.importedPayments.count else { throw IntegrationError.duplicate }
        guard Set(snapshot.categories.map(\.id)).count == snapshot.categories.count,
              Set(snapshot.transactions.map(\.id)).count == snapshot.transactions.count else { throw IntegrationError.duplicate }
        let categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id,$0) })
        let transactions = Dictionary(uniqueKeysWithValues: snapshot.transactions.map { ($0.id,$0) })
        var linked = Set<UUID>()
        for p in snapshot.importedPayments {
            try p.source.validate(); _ = try PaymentDates.parse(p.dueDate)
            guard p.sourceApp == "LifeCost", p.amount > 0, !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  p.name.count <= 100, categories[p.categoryId]?.type == .expense,
                  (p.status == .recorded) == (p.transactionId != nil) else { throw IntegrationError.invalid }
            if let id = p.transactionId {
                guard linked.insert(id).inserted else { throw IntegrationError.duplicate }
                if let t = transactions[id], t.source != .lifecost || t.type != .expense { throw IntegrationError.invalid }
            }
        }
        for setting in snapshot.lifeCostSettings {
            for (code,id) in setting.categoryMappings {
                guard !code.isEmpty, categories[id]?.type == .expense else { throw IntegrationError.invalid }
            }
        }
    }
    public static func protectRestore(current: BackupSnapshot, next: BackupSnapshot) throws {
        let incoming = Dictionary(uniqueKeysWithValues: next.importedPayments.map { ($0.key,$0) })
        for old in current.importedPayments {
            guard let new = incoming[old.key], new.id == old.id, new.source.sourceItemId == old.source.sourceItemId else { throw IntegrationError.changed }
            if old.status != .pending && new.status == .pending { throw IntegrationError.changed }
            if old.status == .recorded && (new.status != .recorded || new.transactionId != old.transactionId) { throw IntegrationError.changed }
        }
    }
}
