import Foundation
import SwiftData
import XCTest
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class FreshStartTests: XCTestCase {
    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        let store = Store(container: try ModelContainer(for: schema,
            migrationPlan: KakeiboMigrationPlan.self, configurations: configuration))
        try store.seed()
        return store
    }

    @MainActor private func model(_ store: Store, defaults: UserDefaults) -> KakeiboViewModel {
        KakeiboViewModel(store: store, preferences: DevicePreferences(defaults: defaults),
                         reminderService: FakeReminders())
    }

    @MainActor func testWelcomeAppearsOnlyForEmptyUserDataAndCanBeDismissedPermanently() throws {
        let store = try store()
        let suite = "kakeibo.welcome.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = model(store, defaults: defaults)
        XCTAssertTrue(first.shouldShowWelcome)
        XCTAssertEqual(first.categories.count, 9)
        first.completeWelcome()
        XCTAssertFalse(first.shouldShowWelcome)
        XCTAssertFalse(model(store, defaults: defaults).shouldShowWelcome)
    }

    @MainActor func testWelcomeDoesNotInterruptEachKindOfExistingData() throws {
        for kind in 0..<4 {
            let store = try store()
            let category = try XCTUnwrap(store.categories(type: .expense).first)
            let finance = FinanceUseCases(repository: store)
            switch kind {
            case 0:
                try store.save(Transaction(type: .expense, amount: 100,
                                           categoryId: category.id, occurredAt: Date()))
            case 1:
                try finance.saveAccount(FinanceAccount(name: "銀行", kind: .bank,
                                                       openingDate: Date(), openingBalance: 100))
            case 2:
                try finance.saveContract(FinanceContract(name: "定期契約", kind: .subscription,
                    categoryId: category.id, expectedAmount: 100, startDate: Date(),
                    firstDueDate: Date()))
            default:
                try finance.saveAsset(OwnedAsset(name: "机", purchaseDate: Date(),
                                                 purchasePrice: 1_000, usefulMonths: 60))
            }
            let suite = "kakeibo.welcome.tests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertFalse(model(store, defaults: defaults).shouldShowWelcome)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor func testNewContractAndAssetDoNotPartiallySaveOnFailure() throws {
        let base = try store()
        let before = try base.snapshot()
        let failingStore = Store(container: base.container,
                                 beforeSave: { throw StoreError.conflict })
        let suite = "kakeibo.welcome.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = model(failingStore, defaults: defaults)
        let category = try XCTUnwrap(model.categories.first { $0.type == .expense })
        let contract = FinanceContract(name: "定期契約", kind: .subscription,
            categoryId: category.id, expectedAmount: 500, startDate: Date(),
            firstDueDate: Date())
        XCTAssertThrowsError(try model.saveContract(contract))
        XCTAssertEqual(try base.snapshot(), before)
        let asset = OwnedAsset(name: "机", purchaseDate: Date(),
                               purchasePrice: 1_000, usefulMonths: 60)
        XCTAssertThrowsError(try model.saveAsset(asset))
        XCTAssertEqual(try base.snapshot(), before)
        XCTAssertTrue(model.shouldShowWelcome)
    }
}
