import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import LifeCostIntegration

final class LegacyRetentionTests: XCTestCase {
    private let datasetId = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private let contractId = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    private let assetId = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!

    @MainActor private func open(_ url: URL) throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let store = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: configuration))
        try store.seed()
        return store
    }

    @MainActor private func legacySnapshot(_ original: BackupSnapshot) throws -> BackupSnapshot {
        var snapshot = original
        let category = try XCTUnwrap(snapshot.categories.first { $0.type == .expense })
        let day = try PaymentDates.parse("2026-10-15")
        let source = PaymentRecord(sourceItemId: contractId, name: "通信", amount: 3_000,
            dueDate: "2026-10-15", category: "通信", paymentType: .subscription,
            now: day)
        snapshot.importedPayments = [try ImportedPayment(datasetId: datasetId,
            source: source, categoryId: category.id)]
        snapshot.lifeCostSettings = [LifeCostSetting(datasetId: datasetId)]
        snapshot.finance = FinanceState(
            contracts: [FinanceContract(id: contractId, name: "通信", kind: .subscription,
                categoryId: category.id, expectedAmount: 3_000,
                startDate: day, firstDueDate: day, legacyDatasetId: datasetId)],
            payments: [ScheduledPayment(contractId: contractId,
                seriesId: snapshot.finance.contracts.first?.seriesId ??
                    UUID(uuidString: "00000000-0000-4000-8000-000000000104")!,
                cycleIndex: 0, dueDate: day, coverageStart: day, expectedAmount: 3_000,
                legacyDatasetId: datasetId, legacySource: source)],
            assets: [OwnedAsset(id: assetId, name: "パソコン", purchaseDate: day,
                purchasePrice: 120_000, usefulMonths: 72, legacyDatasetId: datasetId)],
            importedDatasetIds: [datasetId])
        snapshot.finance.payments[0].seriesId = snapshot.finance.contracts[0].seriesId
        return snapshot
    }

    @MainActor func testExistingLegacyValuesSurviveReopenAndKakeiboBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kakeibo-legacy-retention-" + UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        var expected: BackupSnapshot!
        do {
            let store = try open(url)
            let original = try store.snapshot()
            expected = try legacySnapshot(original)
            try store.apply(expected, expecting: original)
            XCTAssertEqual(try store.snapshot(), expected)
        }
        let reopened = try open(url)
        let actual = try reopened.snapshot()
        XCTAssertEqual(actual, expected)
        let data = try BackupFormat.encode(actual)
        XCTAssertEqual(try BackupFormat.decode(data), actual)
        let preview = try BackupFormat.preview(try BackupFormat.decode(data),
            current: actual, overwrite: false)
        XCTAssertEqual(preview.additions, 0)
        XCTAssertEqual(preview.updates, 0)
        XCTAssertEqual(try reopened.snapshot(), actual)
        let csv = try XCTUnwrap(String(data: BackupFormat.csv(actual), encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("id,type,amount"))
    }
}
