import Foundation
import LifeCostIntegration

public enum LifeCostEngine {
    public static func generate(_ original: LifeCostSnapshot, today: Date) throws -> LifeCostSnapshot {
        try original.validate(); var next = original
        let start = PaymentDates.monthStart(today)
        guard let end = PaymentDates.calendar.date(byAdding: .month, value: 12, to: start) else { throw IntegrationError.invalid }
        _ = try PaymentDates.parse(PaymentDates.string(end))
        var keys = Set(next.occurrences.map(\.key))
        for c in next.contracts {
            let first = try PaymentDates.parse(c.firstDueDate)
            let offset = PaymentDates.calendar.dateComponents([.month], from: PaymentDates.monthStart(first), to: start).month ?? 0
            var index = max(1, offset / (c.finite ? 1 : c.period.months))
            while !c.finite || index <= c.count {
                let text = try c.date(index: index), date = try PaymentDates.parse(text)
                if date >= end || c.endDate.map({ text > $0 }) == true { break }
                let key = c.seriesId.uuidString + ":" + String(index)
                if date >= start, c.generationStart.map({ text >= $0 }) ?? true, !keys.contains(key) {
                    next.occurrences.append(.init(seriesId: c.seriesId, index: index, payment: .init(sourceItemId: c.id, name: c.name, amount: c.amount(index: index), dueDate: text, category: c.category, paymentType: c.type, now: today)))
                    keys.insert(key)
                    guard next.occurrences.count <= 10000 else { throw IntegrationError.tooLarge }
                }
                index += 1
            }
        }
        try next.validate(); return next
    }
    public static func saveContract(_ input: CostContract, in original: LifeCostSnapshot, effectiveFrom: String, today: Date) throws -> LifeCostSnapshot {
        _ = try PaymentDates.parse(effectiveFrom); try input.validate()
        var next = original; var value = input
        if let old = next.contracts.first(where: { $0.id == input.id }) {
            let newSeries = old.firstDueDate != input.firstDueDate || old.period != input.period || old.finite != input.finite
            value.seriesId = newSeries ? UUID() : old.seriesId
            value.generationStart = newSeries ? effectiveFrom : old.generationStart
            for i in next.occurrences.indices where next.occurrences[i].seriesId == old.seriesId {
                let o = next.occurrences[i]
                guard o.payment.status == .scheduled, (o.payment.dueDate ?? "") >= effectiveFrom else { continue }
                if newSeries || (input.finite && o.index > input.count) || input.endDate.map({ (o.payment.dueDate ?? "") > $0 }) == true {
                    try next.occurrences[i].payment.cancel(now: today)
                } else if !o.overridden {
                    let p = PaymentRecord(sourceItemId: value.id, id: o.id, revision: o.payment.revision, name: value.name, amount: value.amount(index: o.index), dueDate: o.payment.dueDate!, category: value.category, paymentType: value.type, now: today)
                    var comparable = p; comparable.updatedAt = o.payment.updatedAt
                    if comparable != o.payment {
                        next.occurrences[i].payment = p
                        next.occurrences[i].payment.revision = try CheckedMoney.add(o.payment.revision, 1)
                    }
                }
            }
        }
        next.contracts.removeAll { $0.id == value.id }; next.contracts.append(value)
        return try generate(next, today: today)
    }
    public static func deleteContract(_ id: UUID, in original: LifeCostSnapshot, today: Date) throws -> LifeCostSnapshot {
        var next = original
        for i in next.occurrences.indices where next.occurrences[i].payment.sourceItemId == id { try next.occurrences[i].payment.cancel(now: today) }
        next.contracts.removeAll { $0.id == id }; try next.validate(); return next
    }
    public static func changeOccurrence(_ id: UUID, amount: Int64, date: String, in original: LifeCostSnapshot, today: Date) throws -> LifeCostSnapshot {
        _ = try PaymentDates.parse(date); guard amount > 0 else { throw IntegrationError.invalid }
        var next = original
        guard let i = next.occurrences.firstIndex(where: { $0.id == id }), next.occurrences[i].payment.status == .scheduled else { throw IntegrationError.changed }
        next.occurrences[i].payment.amount = amount; next.occurrences[i].payment.dueDate = date
        next.occurrences[i].payment.revision = try CheckedMoney.add(next.occurrences[i].payment.revision, 1)
        next.occurrences[i].payment.updatedAt = PaymentDates.timestamp(today); next.occurrences[i].overridden = true
        try next.validate(); return next
    }
    public static func monthlyCost(_ snapshot: LifeCostSnapshot, today: Date) throws -> Decimal {
        try snapshot.validate(); let day = PaymentDates.string(today)
        let assets = snapshot.assets.filter { !$0.archived && $0.purchaseDate <= day }.reduce(Decimal.zero) { $0 + $1.monthlyCost }
        return snapshot.contracts.filter { !$0.finite && $0.startDate <= day && ($0.endDate == nil || $0.endDate! >= day) }
            .reduce(assets) { $0 + Decimal($1.amount) / Decimal($1.period.months) }
    }
    public static func total(_ snapshot: LifeCostSnapshot, month: Date) throws -> Int64 {
        let range = PaymentDates.monthRange(month)
        return try CheckedMoney.sum(snapshot.occurrences.compactMap { o in
            guard o.payment.status == .scheduled, let text = o.payment.dueDate else { return nil }
            return try range.contains(PaymentDates.parse(text)) ? o.payment.amount : nil
        })
    }
    public static func remaining(_ contract: CostContract, in snapshot: LifeCostSnapshot, today: Date) throws -> (count: Int, amount: Int64) {
        guard contract.finite else { throw IntegrationError.invalid }; try contract.validate(); try snapshot.validate()
        let day = PaymentDates.string(today)
        let overrides = Dictionary(uniqueKeysWithValues: snapshot.occurrences.filter { $0.seriesId == contract.seriesId }.map { ($0.index,$0) })
        var count = 0; var total: Int64 = 0
        for index in 1...contract.count {
            let o = overrides[index]
            if o?.payment.status == .cancelled { continue }
            let date = try o?.payment.dueDate ?? contract.date(index: index)
            if date >= day, contract.endDate.map({ date <= $0 }) ?? true, contract.generationStart.map({ date >= $0 }) ?? true {
                total = try CheckedMoney.add(total, o?.payment.amount ?? contract.amount(index: index)); count += 1
            }
        }
        return (count,total)
    }
    public static func prepareExport(_ original: LifeCostSnapshot, today: Date) throws -> (LifeCostSnapshot, PaymentExport) {
        var next = try generate(original, today: today)
        let enabled = Set(next.contracts.filter(\.syncEnabled).map(\.id))
        var payments: [PaymentRecord] = []
        for i in next.occurrences.indices {
            let p = next.occurrences[i].payment
            if p.status == .cancelled ? next.occurrences[i].exported : enabled.contains(p.sourceItemId) {
                next.occurrences[i].exported = true; payments.append(p)
            }
        }
        let start = PaymentDates.monthStart(today), end = PaymentDates.calendar.date(byAdding: .month, value: 12, to: start)!
        let export = PaymentExport(datasetId: next.sourceDatasetId, start: PaymentDates.string(start), end: PaymentDates.string(end), payments: payments, now: today)
        _ = try PaymentExportCodec.encode(export); return (next,export)
    }
}
