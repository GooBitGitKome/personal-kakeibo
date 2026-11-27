import Foundation
import SwiftData
import PersonalKakeiboDomain

@Model final class StoredTransaction {
    var id: UUID = UUID()
    var typeRaw: String = "expense"
    var amount: Int64 = 1
    var categoryId: UUID = UUID()
    var occurredAt: Date = Date()
    var memo: String = ""
    var sourceRaw: String = "manual"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Transaction) {
        id = value.id; typeRaw = value.type.rawValue; amount = value.amount
        categoryId = value.categoryId; occurredAt = value.occurredAt; memo = value.memo
        sourceRaw = value.source.rawValue; createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Transaction) {
        id = value.id
        typeRaw = value.type.rawValue
        amount = value.amount
        categoryId = value.categoryId
        occurredAt = value.occurredAt
        memo = value.memo
        sourceRaw = value.source.rawValue
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Transaction {
        guard let type = TransactionType(rawValue: typeRaw) else { throw StoreError.invalidData }
        guard let source = TransactionSource(rawValue: sourceRaw) else { throw StoreError.invalidData }
        return PersonalKakeiboDomain.Transaction(id: id, type: type, amount: amount, categoryId: categoryId, occurredAt: occurredAt, memo: memo, source: source, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model final class StoredCategory {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = "expense"
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Category) {
        id = value.id; name = value.name; typeRaw = value.type.rawValue
        sortOrder = value.sortOrder; isArchived = value.isArchived
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Category) {
        id = value.id
        name = value.name
        typeRaw = value.type.rawValue
        sortOrder = value.sortOrder
        isArchived = value.isArchived
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Category {
        guard let type = TransactionType(rawValue: typeRaw) else { throw StoreError.invalidData }
        return PersonalKakeiboDomain.Category(id: id, name: name, type: type, sortOrder: sortOrder, isArchived: isArchived, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model final class StoredBudget {
    var id: UUID = UUID()
    var monthKey: String = ""
    var amount: Int64 = 1
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Budget) {
        id = value.id; monthKey = value.monthKey; amount = value.amount
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Budget) {
        id = value.id
        monthKey = value.monthKey
        amount = value.amount
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Budget {
        return PersonalKakeiboDomain.Budget(id: id, monthKey: monthKey, amount: amount, createdAt: createdAt, updatedAt: updatedAt)
    }
}

enum KakeiboSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredTransaction.self, StoredCategory.self, StoredBudget.self] }
}

// The original three entities keep their names and attributes for lightweight migration.
@Model final class StoredPlanningRecord {
    var id: UUID = UUID()
    var kind: String = ""
    var payload: Data = Data()
    var updatedAt: Date = Date()
    init(id: UUID, kind: String, payload: Data, updatedAt: Date) {
        self.id = id; self.kind = kind; self.payload = payload; self.updatedAt = updatedAt
    }
}

enum KakeiboSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] { KakeiboSchemaV1.models + [StoredPlanningRecord.self] }
}

enum KakeiboMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [KakeiboSchemaV1.self, KakeiboSchemaV2.self, KakeiboSchemaV3.self, KakeiboSchemaV4.self, KakeiboSchema.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: KakeiboSchemaV1.self, toVersion: KakeiboSchemaV2.self),
         .lightweight(fromVersion: KakeiboSchemaV2.self, toVersion: KakeiboSchemaV3.self),
         .lightweight(fromVersion: KakeiboSchemaV3.self, toVersion: KakeiboSchemaV4.self),
         .lightweight(fromVersion: KakeiboSchemaV4.self, toVersion: KakeiboSchema.self)]
    }
}

@Model final class StoredLifeCostPayment {
    var id: UUID = UUID()
    var payload: Data = Data()
    init(_ value: ImportedPayment) throws { id = value.id; payload = try JSONEncoder().encode(value) }
    func value() throws -> ImportedPayment {
        let value = try JSONDecoder().decode(ImportedPayment.self, from: payload)
        guard value.id == id else { throw StoreError.invalidData }; return value
    }
}
@Model final class StoredLifeCostSetting {
    var id: UUID = UUID()
    var payload: Data = Data()
    init(_ value: LifeCostSetting) throws { id = value.id; payload = try JSONEncoder().encode(value) }
    func value() throws -> LifeCostSetting {
        let value = try JSONDecoder().decode(LifeCostSetting.self, from: payload)
        guard value.id == id else { throw StoreError.invalidData }; return value
    }
}
enum KakeiboSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3,0,0) }
    static var models: [any PersistentModel.Type] { KakeiboSchemaV2.models + [StoredLifeCostPayment.self, StoredLifeCostSetting.self, StoredSavingsFlag.self] }
}

// A separate entity keeps the historical v1/v2 transaction schema checksums intact.
@Model final class StoredSavingsFlag {
    var transactionId: UUID = UUID()
    var isSavingsEligible: Bool = false
    init(transactionId: UUID, isSavingsEligible: Bool) { self.transactionId = transactionId; self.isSavingsEligible = isSavingsEligible }
}

@Model final class StoredFinanceState {
    var id: UUID = UUID()
    var payload: Data = Data()
    init(_ value: FinanceState) throws {
        id = Self.fixedID
        payload = try JSONEncoder().encode(value)
    }
    static let fixedID = UUID(uuidString: "8F0C6401-6B5D-4DFE-A8DA-72222CC94A38")!
    func value() throws -> FinanceState {
        guard id == Self.fixedID else { throw FinanceError.invalid }
        return try JSONDecoder().decode(FinanceState.self, from: payload)
    }
}

enum KakeiboSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(4,0,0) }
    static var models: [any PersistentModel.Type] { KakeiboSchemaV3.models + [StoredFinanceState.self] }
}

// Per-installation widget draft and commit receipt; excluded from financial backups.
@Model final class StoredWidgetEntry {
    var deviceID: UUID = UUID()
    var payload: Data = Data()
    init(deviceID: UUID, state: WidgetEntryState) throws {
        self.deviceID = deviceID; payload = try JSONEncoder().encode(state)
    }
}

enum KakeiboSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5,0,0) }
    static var models: [any PersistentModel.Type] { KakeiboSchemaV4.models + [StoredWidgetEntry.self] }
}

enum KakeiboLegacyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { Array(KakeiboMigrationPlan.schemas.dropLast()) }
    static var stages: [MigrationStage] { Array(KakeiboMigrationPlan.stages.dropLast()) }
}
