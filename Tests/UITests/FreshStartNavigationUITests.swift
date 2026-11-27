import XCTest

final class FreshStartNavigationUITests: XCTestCase {
    @MainActor func testZSavedEditorsHomeAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(app.staticTexts["当月の実収支（利用日基準）"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["口座とカード"].exists)
        for _ in 0..<5 where !app.staticTexts["これからの支払い"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["これからの支払い"].exists)
        for _ in 0..<5 where !app.staticTexts["契約の期限"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["契約の期限"].exists)
        XCTAssertFalse(app.buttons["契約・サブスクリプション・保険"].exists)
        app.tabBars.buttons["管理"].tap()

        app.buttons["契約・サブスクリプション・保険"].tap()
        app.buttons["契約を追加"].tap()
        let contractName = app.textFields["サービス・契約名"]
        contractName.tap()
        contractName.typeText("テスト契約")
        app.buttons["保存"].tap()
        let contractAlert = app.alerts["保存できませんでした"]
        XCTAssertTrue(contractAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(contractAlert.staticTexts["金額は1以上の整数で入力してください。"].exists)
        contractAlert.buttons["閉じる"].tap()
        XCTAssertEqual(contractName.value as? String, "テスト契約")
        let expectedAmount = app.textFields["予定支払額"]
        expectedAmount.tap()
        expectedAmount.typeText("1000")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["テスト契約"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["管理"].tap()

        app.buttons["所有物・修理費"].tap()
        app.buttons["所有物を追加"].tap()
        let assetName = app.textFields["名称"]
        assetName.tap()
        assetName.typeText("テスト所有物")
        app.buttons["保存"].tap()
        let assetAlert = app.alerts["保存できませんでした"]
        XCTAssertTrue(assetAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(assetAlert.staticTexts["金額、日付、または関連するデータを確認してください。"].exists)
        assetAlert.buttons["閉じる"].tap()
        XCTAssertEqual(assetName.value as? String, "テスト所有物")
        let purchasePrice = app.textFields["購入価格"]
        purchasePrice.tap()
        purchasePrice.typeText("1000")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["テスト所有物"].waitForExistence(timeout: 5))
        app.terminate()

        app.launch()
        XCTAssertFalse(app.staticTexts["新しい家計簿を始める"].exists)
        app.tabBars.buttons["管理"].tap()
        app.buttons["所有物・修理費"].tap()
        XCTAssertTrue(app.staticTexts["テスト所有物"].waitForExistence(timeout: 5))
    }

    @MainActor func testWelcomeActionsAndManagementNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "NO"]

        app.launch()
        XCTAssertTrue(app.staticTexts["新しい家計簿を始める"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["最初に記録したいものを選んでください。後から管理画面でも追加できます。"].exists)
        XCTAssertFalse(app.buttons["旧アプリを読み込む"].exists)
        app.buttons["サブスクリプションを追加"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["管理"].isSelected)
        app.terminate()

        app.launch()
        XCTAssertTrue(app.buttons["所有物を追加"].waitForExistence(timeout: 10))
        app.buttons["所有物を追加"].tap()
        XCTAssertTrue(app.navigationBars["所有物を追加"].waitForExistence(timeout: 5))
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["管理"].isSelected)
        app.terminate()

        app.launch()
        XCTAssertTrue(app.buttons["収支を記録する"].waitForExistence(timeout: 10))
        app.buttons["収支を記録する"].tap()
        XCTAssertTrue(app.navigationBars["収支を入力"].waitForExistence(timeout: 5))
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertTrue(app.tabBars.buttons["設定"].exists)
        XCTAssertFalse(app.tabBars.buttons["リマインダー"].exists)
        XCTAssertFalse(app.navigationBars["管理"].buttons["設定"].exists)
        for destination in ["口座・カード・振替", "支払予定", "契約・サブスクリプション・保険", "所有物・修理費", "リマインダー"] {
            app.buttons[destination].tap()
            if destination == "リマインダー" {
                XCTAssertTrue(app.navigationBars["リマインダー"].waitForExistence(timeout: 5))
            }
            XCTAssertTrue(app.navigationBars.buttons["管理"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["管理"].tap()
            XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 5))
        }
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["管理"].exists)
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "管理と独立した設定タブ"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for tab in ["履歴", "ホーム", "設定", "入力"] {
            app.tabBars.buttons[tab].tap()
            app.tabBars.buttons["管理"].tap()
            XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 5))
        }
    }
}
