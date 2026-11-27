import XCTest

@MainActor enum InlineWidgetUITestSupport {
    static func openOrAdd() -> XCUIApplication {
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home); home.activate()
        for _ in 0..<5 {
            if hasControls(home) { return home }
            home.swipeLeft()
        }
        XCUIDevice.shared.press(.home); XCUIDevice.shared.press(.home)
        let icon = home.icons["家計簿"].firstMatch
        for _ in 0..<5 {
            if icon.exists && icon.isHittable { break }
            home.swipeLeft()
        }
        XCTAssertTrue(icon.exists && icon.isHittable, home.debugDescription)
        icon.press(forDuration: 2)
        tap(["Edit Home Screen", "ホーム画面を編集"], in: home)
        tap(["Edit", "編集"], in: home)
        tap(["Add Widget", " Add Widget", "Add Widgets", "ウィジェットを追加"], in: home)
        let search = home.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("家計簿")
        let app = home.cells["家計簿"].firstMatch
        XCTAssertTrue(app.waitForExistence(timeout: 10)); app.tap()
        let title = home.staticTexts["Widget内で支出を登録"].firstMatch
        for _ in 0..<6 {
            if title.exists && home.frame.contains(title.frame) { break }
            home.swipeLeft()
        }
        XCTAssertTrue(title.exists && home.frame.contains(title.frame), home.debugDescription)
        tap(["Add Widget", " Add Widget", "ウィジェットを追加"], in: home)
        if home.buttons["Done"].exists { home.buttons["Done"].tap() }
        for _ in 0..<5 {
            if hasControls(home) { return home }
            home.swipeLeft()
        }
        XCTFail("テンキーWidgetを表示できませんでした。\n" + home.debugDescription)
        return home
    }
    private static func hasControls(_ home: XCUIApplication) -> Bool {
        home.buttons["今日の支出を登録"].exists || home.buttons["続けて入力"].exists || home.buttons["入力に戻る"].exists
    }
    private static func tap(_ labels: [String], in app: XCUIApplication) {
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) { button.tap(); return }
        }
        XCTFail("ボタンが見つかりません: \(labels)\n" + app.debugDescription)
    }
}

final class InlineWidgetDisabledButtonsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testUnavailableControlsConsumeTapsWithoutLaunchingApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["入力"].waitForExistence(timeout: 15))
        app.terminate()
        let home = InlineWidgetUITestSupport.openOrAdd()
        if home.buttons["続けて入力"].exists { home.buttons["続けて入力"].tap() }
        if home.buttons["入力に戻る"].exists { home.buttons["入力に戻る"].tap() }
        home.buttons["金額を全消去"].tap()
        let save = home.buttons["今日の支出を登録"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        for x in [0.05, 0.5, 0.95] {
            save.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            XCTAssertNotEqual(app.state, .runningForeground)
            XCTAssertTrue(home.staticTexts["入力金額 0円"].exists)
            XCTAssertFalse(home.staticTexts["登録しました"].exists)
        }
        home.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ジャンル：")).firstMatch.tap()
        XCTAssertTrue(home.staticTexts["1/2"].waitForExistence(timeout: 10))
        home.buttons["前へ"].tap()
        XCTAssertNotEqual(app.state, .runningForeground)
        XCTAssertTrue(home.staticTexts["1/2"].exists)
        home.buttons["次へ"].tap()
        XCTAssertTrue(home.staticTexts["2/2"].waitForExistence(timeout: 10))
        home.buttons["次へ"].tap()
        XCTAssertNotEqual(app.state, .runningForeground)
        XCTAssertTrue(home.staticTexts["2/2"].exists)
        home.buttons["その他"].tap()
        home.buttons["9"].tap(); home.buttons["ゼロを2桁入力"].tap()
        save.tap()
        XCTAssertTrue(home.staticTexts["登録しました"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        home.buttons["取り消す"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
    }
}
