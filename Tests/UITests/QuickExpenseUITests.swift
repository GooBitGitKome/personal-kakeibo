import XCTest

final class QuickExpenseUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testWidgetOpensFullscreenWithLargeKeysAndRetainsDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["入力"].waitForExistence(timeout: 15))
        app.terminate()
        openWidget()
        XCTAssertTrue(app.navigationBars["支出を入力"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let one = app.buttons["quick.key.1"]
        XCTAssertGreaterThanOrEqual(one.frame.height, 64)
        XCTAssertGreaterThanOrEqual(one.frame.width, 64)
        tapVisible("金額を全消去", in: app)
        one.tap(); app.buttons["quick.key.00"].tap()
        app.buttons["quick.key.⌫"].tap(); app.buttons["quick.key.9"].tap()
        XCTAssertTrue(app.staticTexts["入力金額 109円"].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ジャンル：")).firstMatch.tap()
        tapVisible("食費", in: app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "支払元：")).firstMatch.tap()
        tapVisible("未指定", in: app)
        attach(app, name: "全画面入力・大きなテンキー")
        app.buttons["quick.save"].tap()
        XCTAssertTrue(app.staticTexts["登録しました"].waitForExistence(timeout: 10))
        app.buttons["取り消す"].tap()
        XCTAssertTrue(app.buttons["quick.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["入力金額 109円"].exists)
        app.buttons["quick.save"].tap()
        XCTAssertTrue(app.staticTexts["登録しました"].waitForExistence(timeout: 10))
        tapVisible("閉じる", in: app)
        app.tabBars.buttons["履歴"].tap()
        XCTAssertTrue(app.staticTexts["支出 109円"].waitForExistence(timeout: 10))
        openWidget()
        XCTAssertTrue(app.buttons["quick.save"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["入力金額 0円"].exists)
        app.buttons["quick.key.7"].tap()
        tapVisible("閉じる", in: app)
        openWidget()
        XCTAssertTrue(app.buttons["quick.save"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["入力金額 7円"].exists)
        tapVisible("閉じる", in: app)
        app.terminate()
    }

    @MainActor private func tapVisible(_ label: String, in app: XCUIApplication) {
        let matches = app.buttons.matching(identifier: label).allElementsBoundByIndex
        guard let button = matches.first(where: { $0.isHittable }) else {
            XCTFail("操作できるボタンが見つかりません: " + label); return
        }
        button.tap()
    }

    @MainActor private func openWidget() {
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        home.activate()
        let icon = home.icons["家計簿"].firstMatch
        for _ in 0..<5 {
            if icon.exists && icon.isHittable { break }
            home.swipeLeft()
        }
        XCTAssertTrue(icon.exists && icon.isHittable, home.debugDescription)
        icon.tap()
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
