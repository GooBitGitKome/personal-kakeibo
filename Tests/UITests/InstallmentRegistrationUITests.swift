import XCTest

/// Opens the installment registration screen from a fresh store. With no accounts registered the
/// screen must explain what is missing and keep saving disabled.
final class InstallmentRegistrationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testRegistrationIsBlockedUntilAccountsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 10))
        app.tabBars.buttons["管理"].tap()
        let contracts = app.buttons["契約・サブスクリプション・保険"]
        for _ in 0..<12 where !(contracts.exists && contracts.isHittable) { app.swipeUp() }
        contracts.tap()
        let add = app.buttons["contracts.addInstallment"]
        for _ in 0..<12 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.navigationBars["分割払いを登録"].waitForExistence(timeout: 5))

        let save = app.navigationBars.buttons["installment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["installment.problem"].exists)

        let name = app.textFields["installment.name"]
        name.tap()
        name.typeText("パソコン")
        XCTAssertFalse(save.isEnabled)
        app.navigationBars.buttons["キャンセル"].tap()
        XCTAssertTrue(app.buttons["contracts.addInstallment"].waitForExistence(timeout: 5))
        app.terminate()
    }
}
