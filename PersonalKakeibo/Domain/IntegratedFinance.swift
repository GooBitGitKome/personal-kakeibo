import Foundation
import LifeCostIntegration

public enum FinanceError: Error, Equatable, LocalizedError {
    case invalid, duplicate, missing, changed, overflow

    public var errorDescription: String? {
        switch self {
        case .invalid: "金額、日付、または関連するデータを確認してください。"
        case .duplicate: "同じデータが既に登録されています。"
        case .missing: "関連するデータが見つかりません。"
        case .changed: "データが変更されました。再読み込みしてください。"
        case .overflow: "金額が計算できる範囲を超えています。"
        }
    }
}

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case cash, bank, creditCard, loan
    public var label: String {
        switch self {
        case .cash: "現金"
        case .bank: "銀行口座"
        case .creditCard: "クレジットカード"
        case .loan: "借入金"
        }
    }
    public var isLiability: Bool { self == .creditCard || self == .loan }
}

public struct FinanceAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AccountKind
    public var openingDate: Date
    /// Asset balances and outstanding liabilities are both stored as positive amounts.
    public var openingBalance: Int64
    public var isArchived: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, kind: AccountKind, openingDate: Date,
                openingBalance: Int64, isArchived: Bool = false, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind
        self.openingDate = Month.calendar.startOfDay(for: openingDate)
        self.openingBalance = openingBalance; self.isArchived = isArchived; self.updatedAt = updatedAt
    }
}

public enum PostingKind: String, Codable, Sendable {
    case transaction, refund, transfer, cardSettlement, loanSettlement
}

public struct AccountPosting: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var accountId: UUID
    public var eventId: UUID
    public var kind: PostingKind
    public var date: Date
    /// Positive increases an asset balance or an outstanding liability.
    public var amount: Int64

    public init(id: UUID = UUID(), accountId: UUID, eventId: UUID, kind: PostingKind,
                date: Date, amount: Int64) {
        self.id = id; self.accountId = accountId; self.eventId = eventId
        self.kind = kind; self.date = date; self.amount = amount
    }
}

public enum BillingUnit: String, Codable, CaseIterable, Sendable {
    case day, week, month, year
    public var label: String {
        switch self {
        case .day: "日"
        case .week: "週"
        case .month: "か月"
        case .year: "年"
        }
    }
}

public struct BillingInterval: Codable, Equatable, Sendable {
    public var count: Int
    public var unit: BillingUnit

    public init(count: Int = 1, unit: BillingUnit = .month) {
        self.count = count; self.unit = unit
    }

    public func date(from anchor: Date, index: Int) throws -> Date {
        guard (1...1200).contains(count), (0...10000).contains(index) else { throw FinanceError.invalid }
        let product = count.multipliedReportingOverflow(by: index)
        guard !product.overflow else { throw FinanceError.overflow }
        let calendar = Month.calendar
        let start = calendar.startOfDay(for: anchor)
        switch unit {
        case .day, .week:
            let days = product.partialValue.multipliedReportingOverflow(by: unit == .week ? 7 : 1)
            guard !days.overflow, let result = calendar.date(byAdding: .day, value: days.partialValue, to: start) else { throw FinanceError.invalid }
            return result
        case .month, .year:
            let months = product.partialValue.multipliedReportingOverflow(by: unit == .year ? 12 : 1)
            guard !months.overflow,
                  let target = calendar.date(byAdding: .month, value: months.partialValue, to: Month(date: start).start),
                  let days = calendar.range(of: .day, in: .month, for: target),
                  let result = calendar.date(byAdding: .day, value: min(calendar.component(.day, from: start), days.count) - 1, to: target)
            else { throw FinanceError.invalid }
            return result
        }
    }

    public var coverageMonths: Int? {
        switch unit {
        case .day, .week: nil
        case .month: count
        case .year: count * 12
        }
    }

    /// Stable comparison figure; actual calendar-month allocations are calculated separately.
    public func monthlyEquivalent(_ amount: Int64) throws -> Decimal {
        guard amount >= 0, (1...1200).contains(count) else { throw FinanceError.invalid }
        return switch unit {
        case .day: Decimal(amount) * Decimal(146097) / Decimal(400 * 12 * count)
        case .week: Decimal(amount) * Decimal(146097) / Decimal(400 * 12 * 7 * count)
        case .month: Decimal(amount) / Decimal(count)
        case .year: Decimal(amount) / Decimal(12 * count)
        }
    }
}

public enum ContractKind: String, Codable, CaseIterable, Sendable {
    case subscription, insurance, fixedCost, installment, loan
    public var label: String {
        switch self {
        case .subscription: "サブスクリプション"
        case .insurance: "保険"
        case .fixedCost: "その他の固定費"
        case .installment: "分割払い"
        case .loan: "ローン"
        }
    }
}

public enum ContractStatus: String, Codable, CaseIterable, Sendable {
    case active, cancellationPlanned, ended
}

public struct InsuranceDetails: Codable, Equatable, Sendable {
    public var company: String
    public var productName: String
    public var insuranceType: String
    public var coverage: String
    public var insuredAmount: Int64?
    public var deductible: Int64?
    public var maturityDate: Date?
    public var cancellationTerms: String
    public var reviewDate: Date?

    public init(company: String = "", productName: String = "", insuranceType: String = "",
                coverage: String = "", insuredAmount: Int64? = nil, deductible: Int64? = nil,
                maturityDate: Date? = nil, cancellationTerms: String = "", reviewDate: Date? = nil) {
        self.company = company; self.productName = productName; self.insuranceType = insuranceType
        self.coverage = coverage; self.insuredAmount = insuredAmount; self.deductible = deductible
        self.maturityDate = maturityDate; self.cancellationTerms = cancellationTerms; self.reviewDate = reviewDate
    }
}

public struct FinanceContract: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var seriesId: UUID
    public var name: String
    public var kind: ContractKind
    public var categoryId: UUID
    public var expectedAmount: Int64
    public var isVariable: Bool
    public var interval: BillingInterval
    public var startDate: Date
    public var firstDueDate: Date
    public var endDate: Date?
    public var renewalDate: Date?
    public var cancellationDeadline: Date?
    public var autoRenew: Bool
    public var automaticallyRecordPayment: Bool?
    public var status: ContractStatus
    public var paymentAccountId: UUID?
    public var liabilityAccountId: UUID?
    public var necessity: String
    public var usageFrequency: String
    public var memo: String
    public var insurance: InsuranceDetails?
    public var financedAssetId: UUID?
    public var maximumCycles: Int?
    public var finalAmount: Int64?
    public var principal: Int64?
    public var generationStart: Date?
    public var legacySyncEnabled: Bool?
    public var replacedRecurringPlanId: UUID?
    public var legacyDatasetId: UUID?
    public var updatedAt: Date

    public init(id: UUID = UUID(), seriesId: UUID = UUID(), name: String, kind: ContractKind,
                categoryId: UUID, expectedAmount: Int64, isVariable: Bool = false,
                interval: BillingInterval = .init(), startDate: Date, firstDueDate: Date,
                endDate: Date? = nil, renewalDate: Date? = nil, cancellationDeadline: Date? = nil,
                autoRenew: Bool = false, status: ContractStatus = .active,
                paymentAccountId: UUID? = nil, liabilityAccountId: UUID? = nil,
                necessity: String = "", usageFrequency: String = "",
                memo: String = "", insurance: InsuranceDetails? = nil,
                financedAssetId: UUID? = nil, maximumCycles: Int? = nil,
                finalAmount: Int64? = nil, principal: Int64? = nil,
                generationStart: Date? = nil, legacySyncEnabled: Bool? = nil,
                replacedRecurringPlanId: UUID? = nil, legacyDatasetId: UUID? = nil,
                updatedAt: Date = Date()) {
        self.id = id; self.seriesId = seriesId; self.name = name; self.kind = kind
        self.categoryId = categoryId; self.expectedAmount = expectedAmount; self.isVariable = isVariable
        self.interval = interval; self.startDate = startDate; self.firstDueDate = firstDueDate
        self.endDate = endDate; self.renewalDate = renewalDate; self.cancellationDeadline = cancellationDeadline
        self.automaticallyRecordPayment = nil
        self.autoRenew = autoRenew; self.status = status; self.paymentAccountId = paymentAccountId
        self.liabilityAccountId = liabilityAccountId
        self.necessity = necessity; self.usageFrequency = usageFrequency; self.memo = memo
        self.insurance = insurance; self.financedAssetId = financedAssetId
        self.maximumCycles = maximumCycles; self.finalAmount = finalAmount
        self.principal = principal; self.generationStart = generationStart
        self.legacySyncEnabled = legacySyncEnabled
        self.replacedRecurringPlanId = replacedRecurringPlanId
        self.legacyDatasetId = legacyDatasetId; self.updatedAt = updatedAt
    }
}

public enum ScheduledPaymentStatus: String, Codable, Sendable {
    case pending, recorded, skipped, cancelled
}

public struct ScheduledPayment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var contractId: UUID
    public var seriesId: UUID
    public var cycleIndex: Int
    public var dueDate: Date
    public var coverageStart: Date
    public var expectedAmount: Int64
    public var actualAmount: Int64?
    public var principalAmount: Int64?
    public var interestAmount: Int64?
    public var status: ScheduledPaymentStatus
    public var transactionId: UUID?
    public var settlementEventId: UUID?
    public var isOverridden: Bool
    public var legacyDatasetId: UUID?
    public var legacySource: PaymentRecord?
    public var updatedAt: Date
    public var key: String { seriesId.uuidString + ":" + String(cycleIndex) }

    public init(id: UUID = UUID(), contractId: UUID, seriesId: UUID, cycleIndex: Int,
                dueDate: Date, coverageStart: Date, expectedAmount: Int64,
                actualAmount: Int64? = nil, principalAmount: Int64? = nil,
                interestAmount: Int64? = nil, status: ScheduledPaymentStatus = .pending,
                transactionId: UUID? = nil, settlementEventId: UUID? = nil,
                isOverridden: Bool = false, legacyDatasetId: UUID? = nil,
                legacySource: PaymentRecord? = nil, updatedAt: Date = Date()) {
        self.id = id; self.contractId = contractId; self.seriesId = seriesId
        self.cycleIndex = cycleIndex; self.dueDate = dueDate; self.coverageStart = coverageStart
        self.expectedAmount = expectedAmount; self.actualAmount = actualAmount
        self.principalAmount = principalAmount; self.interestAmount = interestAmount
        self.status = status; self.transactionId = transactionId
        self.settlementEventId = settlementEventId; self.isOverridden = isOverridden
        self.legacyDatasetId = legacyDatasetId; self.legacySource = legacySource
        self.updatedAt = updatedAt
    }
}

public struct OwnedAsset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var category: String
    public var purchaseDate: Date
    public var purchasePrice: Int64
    public var expectedResidual: Int64
    public var usefulMonths: Int
    public var isUsed: Bool
    public var releaseDate: Date?
    public var warrantyEnd: Date?
    public var supportEnd: Date?
    public var saleDate: Date?
    public var salePrice: Int64?
    public var purchaseTransactionId: UUID?
    public var saleTransactionId: UUID?
    public var memo: String
    public var legacyDatasetId: UUID?
    public var legacyPurchaseMethod: String?
    public var legacyPaid: Bool?
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, category: String = "その他",
                purchaseDate: Date, purchasePrice: Int64, expectedResidual: Int64 = 0,
                usefulMonths: Int, isUsed: Bool = false, releaseDate: Date? = nil,
                warrantyEnd: Date? = nil, supportEnd: Date? = nil,
                saleDate: Date? = nil, salePrice: Int64? = nil,
                purchaseTransactionId: UUID? = nil, saleTransactionId: UUID? = nil,
                memo: String = "", legacyDatasetId: UUID? = nil,
                legacyPurchaseMethod: String? = nil, legacyPaid: Bool? = nil,
                updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.category = category
        self.purchaseDate = purchaseDate; self.purchasePrice = purchasePrice
        self.expectedResidual = expectedResidual; self.usefulMonths = usefulMonths
        self.isUsed = isUsed; self.releaseDate = releaseDate; self.warrantyEnd = warrantyEnd
        self.supportEnd = supportEnd; self.saleDate = saleDate; self.salePrice = salePrice
        self.purchaseTransactionId = purchaseTransactionId; self.saleTransactionId = saleTransactionId
        self.memo = memo; self.legacyDatasetId = legacyDatasetId
        self.legacyPurchaseMethod = legacyPurchaseMethod; self.legacyPaid = legacyPaid
        self.updatedAt = updatedAt
    }
}

public struct AssetRepair: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var assetId: UUID
    public var date: Date
    public var amount: Int64
    public var transactionId: UUID?
    public var memo: String

    public init(id: UUID = UUID(), assetId: UUID, date: Date, amount: Int64,
                transactionId: UUID? = nil, memo: String = "") {
        self.id = id; self.assetId = assetId; self.date = date
        self.amount = amount; self.transactionId = transactionId; self.memo = memo
    }
}

public struct FinanceRefund: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var originalTransactionId: UUID
    public var date: Date
    public var amount: Int64
    public var accountId: UUID?
    public var memo: String

    public init(id: UUID = UUID(), originalTransactionId: UUID, date: Date,
                amount: Int64, accountId: UUID? = nil, memo: String = "") {
        self.id = id; self.originalTransactionId = originalTransactionId
        self.date = date; self.amount = amount; self.accountId = accountId; self.memo = memo
    }
}

public struct FinanceState: Codable, Equatable, Sendable {
    public var accounts: [FinanceAccount]
    public var postings: [AccountPosting]
    public var contracts: [FinanceContract]
    public var payments: [ScheduledPayment]
    public var assets: [OwnedAsset]
    public var repairs: [AssetRepair]
    public var refunds: [FinanceRefund]
    public var importedDatasetIds: [UUID]

    public init(accounts: [FinanceAccount] = [], postings: [AccountPosting] = [],
                contracts: [FinanceContract] = [], payments: [ScheduledPayment] = [],
                assets: [OwnedAsset] = [], repairs: [AssetRepair] = [],
                refunds: [FinanceRefund] = [],
                importedDatasetIds: [UUID] = []) {
        self.accounts = accounts; self.postings = postings; self.contracts = contracts
        self.payments = payments; self.assets = assets; self.repairs = repairs
        self.refunds = refunds
        self.importedDatasetIds = importedDatasetIds
    }
}
