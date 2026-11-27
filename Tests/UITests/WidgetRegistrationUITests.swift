import XCTest

final class WidgetRegistrationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testWidgetRegistrationFromHomeScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["入力"].waitForExistence(timeout: 15), app.debugDescription)
        app.terminate()
        let home = InlineWidgetUITestSupport.openOrAdd()
        if home.buttons["続けて入力"].exists { home.buttons["続けて入力"].tap() }
        if home.buttons["入力に戻る"].exists { home.buttons["入力に戻る"].tap() }
        home.buttons["金額を全消去"].tap()
        let register = home.buttons["今日の支出を登録"].firstMatch
        XCTAssertTrue(register.waitForExistence(timeout: 15), home.debugDescription)
        attach(home, name: "Widget入力画面・iPhone 12 mini")
        for key in ["6", "0", "2", "7"] { home.buttons[key].tap() }
        home.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ジャンル：")).firstMatch.tap()
        home.buttons["交通費"].tap()
        register.tap()
        XCTAssertTrue(home.staticTexts["登録しました"].waitForExistence(timeout: 10), home.debugDescription)
        XCTAssertNotEqual(app.state, .runningForeground)
        attach(home, name: "Widgetで支出登録・アプリ未表示")
        home.buttons["取り消す"].tap()
        XCTAssertTrue(register.waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        register.tap()
        XCTAssertTrue(home.staticTexts["登録しました"].waitForExistence(timeout: 10))
        app.launch()
        app.tabBars.buttons["履歴"].tap()
        XCTAssertTrue(app.staticTexts["支出 6,027円"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "支出 6,027円").count, 1)
        XCTAssertTrue(app.staticTexts["交通費"].exists)
        app.terminate()
    }

    @MainActor func testWidgetSelectorsAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 15))
        app.tabBars.buttons["管理"].tap()
        app.buttons["口座・カード・振替"].tap()
        if !app.staticTexts["Widget支払元"].exists {
            let add = app.buttons["口座を追加"]
            for _ in 0..<5 { if add.isHittable { break }; app.swipeUp() }
            add.tap()
            app.textFields["口座名"].tap(); app.textFields["口座名"].typeText("Widget支払元")
            app.navigationBars.buttons["保存"].tap()
            XCTAssertTrue(app.staticTexts["Widget支払元"].waitForExistence(timeout: 10))
        }
        app.terminate()
        let home = InlineWidgetUITestSupport.openOrAdd()
        let register = home.buttons["今日の支出を登録"].firstMatch
        let next = home.buttons["続けて入力"].firstMatch
        if next.exists { next.tap() }
        XCTAssertTrue(register.waitForExistence(timeout: 15), home.debugDescription)
        home.buttons["金額を全消去"].tap()
        home.buttons["1"].tap(); home.buttons["ゼロを2桁入力"].tap()
        home.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ジャンル：")).firstMatch.tap()
        home.buttons["次へ"].tap()
        XCTAssertTrue(home.buttons["その他"].waitForExistence(timeout: 10))
        home.buttons["その他"].tap()
        home.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "支払元：")).firstMatch.tap()
        home.buttons["Widget支払元"].tap()
        XCTAssertTrue(home.buttons["支払元：Widget支払元"].waitForExistence(timeout: 10))
        for label in ["0","1","2","3","4","5","6","7","8","9","ゼロを2桁入力","1桁削除","金額を全消去"] {
            XCTAssertTrue(home.buttons[label].isHittable, label)
        }
        attach(home, name: "Widget・最大文字でジャンルと支払元を選択")
        register.tap()
        XCTAssertTrue(home.staticTexts["登録しました"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        attach(home, name: "Widget・最大文字で登録完了")
        home.buttons["取り消す"].tap()
        XCTAssertTrue(register.waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
    }

    @MainActor private func tapAny(_ labels: [String], in app: XCUIApplication) {
        for label in labels {
            if app.buttons[label].firstMatch.waitForExistence(timeout: 2) {
                app.buttons[label].firstMatch.tap(); return
            }
        }
        XCTFail("ボタンが見つかりません: \(labels)\n\(app.debugDescription)")
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
