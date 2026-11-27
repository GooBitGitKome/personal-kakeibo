import XCTest

final class SubscriptionServiceSelectionUITests: XCTestCase {
    private let services = [
        "Netflix", "Disney+", "Hulu", "U-NEXT", "DAZN", "YouTube Premium",
        "Apple Music", "Spotify", "iCloud+", "Google One", "Microsoft 365",
        "Adobe Creative Cloud", "ChatGPT", "Amazonプライム"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testAWelcomeCatalogVisibilityAndCancelledCreation() {
        let app = launch(welcome: true)
        XCTAssertTrue(app.buttons["サブスクリプションを追加"].waitForExistence(timeout: 10))
        app.buttons["サブスクリプションを追加"].tap()
        openPicker(app)
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        XCTAssertTrue(app.buttons["その他・手入力"].isHittable)
        attach(app, name: "サービス候補・標準文字")
        for service in services {
            reveal(app.buttons[service], in: app)
            XCTAssertTrue(app.buttons[service].isHittable)
        }
        app.navigationBars.buttons["契約を追加"].tap()
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "")
        selectOption("保険", control: control("contract.kind", in: app), in: app)
        XCTAssertFalse(app.buttons["サービスから選ぶ"].exists)
        selectOption("サブスクリプション", control: control("contract.kind", in: app), in: app)
        openPicker(app)
        app.buttons["その他・手入力"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "")
        app.navigationBars.buttons["キャンセル"].tap()
        XCTAssertTrue(app.tabBars.buttons["管理"].isSelected)

        openNewContract(app)
        app.textFields["contract.name"].tap()
        app.textFields["contract.name"].typeText("   ")
        openPicker(app)
        app.buttons["Netflix"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["サービス名を置き換えますか？"].exists)
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Netflix")
        XCTAssertEqual(textValue(app.textFields["contract.amount"]), "")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.alerts["保存できませんでした"].waitForExistence(timeout: 5))
        app.alerts.buttons["閉じる"].tap()
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Netflix")
        app.navigationBars.buttons["キャンセル"].tap()
        XCTAssertTrue(app.staticTexts["契約はまだありません。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Netflix"].exists)
        app.navigationBars.buttons["管理"].tap()
        app.buttons["支払予定"].tap()
        XCTAssertTrue(app.staticTexts["予定はありません。"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor func testBReplacementPreservesContractFieldsAndSavesOriginalName() {
        let app = launch()
        app.tabBars.buttons["管理"].tap()
        app.buttons["口座・カード・振替"].tap()
        app.buttons["口座を追加"].tap()
        app.textFields["口座名"].tap()
        app.textFields["口座名"].typeText("選択テスト口座")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["選択テスト口座"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["管理"].tap()
        openNewContract(app, fromManagement: true)

        app.textFields["contract.name"].tap()
        app.textFields["contract.name"].typeText("元の契約")
        selectOption("娯楽費", control: control("contract.category", in: app), in: app)
        app.textFields["contract.amount"].tap()
        app.textFields["contract.amount"].typeText("1299")
        selectOption("選択テスト口座", control: control("contract.paymentAccount", in: app), in: app)
        let interval = control("contract.intervalCount", in: app)
        reveal(interval, in: app)
        interval.buttons.element(boundBy: 1).tap()
        selectOption("年", control: control("contract.intervalUnit", in: app), in: app)
        let before = contractValues(app)
        XCTAssertTrue(before["contract.category", default: ""].contains("娯楽費"))
        XCTAssertTrue(before["contract.amount", default: ""].contains("1299"))
        XCTAssertTrue(before["contract.paymentAccount", default: ""].contains("選択テスト口座"))
        XCTAssertTrue(before["contract.intervalUnit", default: ""].contains("年"))
        for date in ["contract.startDate", "contract.firstDueDate"] {
            XCTAssertNotNil(before[date]?.rangeOfCharacter(from: .decimalDigits))
        }

        openPicker(app)
        app.buttons["Netflix"].tap()
        let confirmation = app.alerts["サービス名を置き換えますか？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["キャンセル"].tap()
        XCTAssertTrue(app.navigationBars["サービスを選ぶ"].exists)
        app.navigationBars.buttons["契約を追加"].tap()
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "元の契約")
        XCTAssertEqual(contractValues(app), before)

        openPicker(app)
        app.buttons["Netflix"].tap()
        app.alerts.buttons["置き換える"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Netflix")
        XCTAssertEqual(contractValues(app), before)
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Netflix"].waitForExistence(timeout: 5))
        app.staticTexts["Netflix"].tap()
        XCTAssertTrue(app.navigationBars["契約を編集"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["サービスから選ぶ"].exists)
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Netflix")
        app.navigationBars.buttons["キャンセル"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["管理"].tap()
        app.buttons["契約・サブスクリプション・保険"].tap()
        XCTAssertTrue(app.staticTexts["Netflix"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor func testCManualNameSameSelectionKindChangesAndRestart() {
        let app = launch()
        openNewContract(app)
        openPicker(app)
        reveal(app.buttons["Spotify"], in: app)
        app.buttons["Spotify"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Spotify")
        openPicker(app)
        reveal(app.buttons["Spotify"], in: app)
        app.buttons["Spotify"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["サービス名を置き換えますか？"].exists)
        openPicker(app)
        app.navigationBars.buttons["契約を追加"].tap()
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Spotify")
        openPicker(app)
        app.buttons["その他・手入力"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.textFields["contract.name"].typeText(" 家族用")
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Spotify 家族用")
        selectOption("保険", control: control("contract.kind", in: app), in: app)
        XCTAssertFalse(app.buttons["サービスから選ぶ"].exists)
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Spotify 家族用")
        selectOption("サブスクリプション", control: control("contract.kind", in: app), in: app)
        XCTAssertTrue(app.buttons["サービスから選ぶ"].exists)
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Spotify 家族用")
        app.textFields["contract.amount"].tap()
        app.textFields["contract.amount"].typeText("500")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Spotify 家族用"].waitForExistence(timeout: 5))
        app.terminate()

        app.launch()
        app.tabBars.buttons["管理"].tap()
        app.buttons["契約・サブスクリプション・保険"].tap()
        XCTAssertTrue(app.staticTexts["Spotify 家族用"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor func testDSubscriptionBatchConfirmationAndHistoryTag() {
        let app = launch()
        openNewContract(app)
        XCTAssertTrue(app.switches["支払日に自動確定"].exists)
        app.textFields["contract.name"].tap()
        app.textFields["contract.name"].typeText("一括テスト")
        app.textFields["contract.amount"].tap()
        app.textFields["contract.amount"].typeText("800")
        app.navigationBars.buttons["保存"].tap()
        let batch = app.buttons["今月分をまとめて確定"]
        reveal(batch, in: app, upwards: false)
        batch.tap()
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(batch.isEnabled)
        batch.tap()
        app.buttons["支払いを確定"].tap()
        XCTAssertFalse(batch.isEnabled)
        app.tabBars.buttons["履歴"].tap()
        let tag = app.staticTexts["管理・サブスク：一括テスト"]
        reveal(tag, in: app)
        XCTAssertTrue(tag.isHittable)
        attach(app, name: "サブスク一括確定の履歴タグ")
        app.terminate()
    }

    @MainActor func testLargeTextCatalog() {
        let app = launch()
        openNewContract(app)
        openPicker(app)
        XCTAssertTrue(app.buttons["その他・手入力"].isHittable)
        attach(app, name: "サービス候補・アクセシビリティ最大文字")
        for service in services {
            reveal(app.buttons[service], in: app, maximumSwipes: 25)
            XCTAssertTrue(app.buttons[service].isHittable)
        }
        attach(app, name: "サービス候補・最大文字で一覧下端")
        app.buttons["Amazonプライム"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
        reveal(app.textFields["contract.name"], in: app)
        XCTAssertEqual(textValue(app.textFields["contract.name"]), "Amazonプライム")
        app.navigationBars.buttons["キャンセル"].tap()
        app.terminate()
    }

    @MainActor private func launch(welcome: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", welcome ? "NO" : "YES"]
        app.launch()
        return app
    }

    @MainActor private func openNewContract(_ app: XCUIApplication, fromManagement: Bool = false) {
        if !fromManagement {
            XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 10))
            app.tabBars.buttons["管理"].tap()
        }
        reveal(app.buttons["契約・サブスクリプション・保険"], in: app)
        app.buttons["契約・サブスクリプション・保険"].tap()
        reveal(app.buttons["契約を追加"], in: app)
        app.buttons["契約を追加"].tap()
        XCTAssertTrue(app.navigationBars["契約を追加"].waitForExistence(timeout: 5))
    }

    @MainActor private func openPicker(_ app: XCUIApplication) {
        let button = app.buttons["サービスから選ぶ"]
        reveal(button, in: app, upwards: false)
        button.tap()
        XCTAssertTrue(app.navigationBars["サービスを選ぶ"].waitForExistence(timeout: 5))
    }

    @MainActor private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func selectOption(_ option: String, control: XCUIElement, in app: XCUIApplication) {
        reveal(control, in: app)
        control.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                                    upwards: Bool = true, maximumSwipes: Int = 12) {
        for _ in 0..<maximumSwipes {
            if element.exists && element.isHittable { return }
            scroll(app, upwards: upwards)
        }
        XCTAssertTrue(element.exists && element.isHittable, "画面上で操作できません: \(element)")
    }

    @MainActor private func scroll(_ app: XCUIApplication, upwards: Bool) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else {
            if upwards { app.swipeUp() } else { app.swipeDown() }
            return
        }
        // Use the foreground sheet above the keyboard, not a background collection view.
        let top: CGFloat = 200
        let bottom = keyboard.frame.minY - 30
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.midX
        let start = origin.withOffset(CGVector(dx: x, dy: upwards ? bottom : top))
        let end = origin.withOffset(CGVector(dx: x, dy: upwards ? top : bottom))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor private func textValue(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    @MainActor private func contractValues(_ app: XCUIApplication) -> [String: String] {
        reveal(app.buttons["サービスから選ぶ"], in: app, upwards: false)
        var result: [String: String] = [:]
        for id in ["contract.category", "contract.amount", "contract.paymentAccount",
                   "contract.intervalCount", "contract.intervalUnit", "contract.startDate", "contract.firstDueDate"] {
            let item = control(id, in: app)
            reveal(item, in: app)
            let value = item.value as? String ?? ""
            let children = item.buttons.allElementsBoundByIndex.map { $0.label + ":" + (($0.value as? String) ?? "") }
            result[id] = ([item.label, value] + children).joined(separator: "|")
        }
        return result
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
