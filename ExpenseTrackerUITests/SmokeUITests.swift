import XCTest

/// Signs in against the configured server and walks through every tab.
/// Needs a test account: `TEST_RUNNER_UITEST_EMAIL=… TEST_RUNNER_UITEST_PASSWORD=… xcodebuild test …`
final class SmokeUITests: XCTestCase {
    @MainActor
    func testSignInAddTransactionAndOpenTabs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["UITEST_EMAIL"], let password = env["UITEST_PASSWORD"] else {
            throw XCTSkip("Set UITEST_EMAIL and UITEST_PASSWORD")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()

        if app.textFields["Email"].waitForExistence(timeout: 5) {
            app.textFields["Email"].tap()
            app.textFields["Email"].typeText(email)
            app.secureTextFields["Пароль"].tap()
            app.secureTextFields["Пароль"].typeText(password)
            app.buttons["Войти"].tap()
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15))
        snapshot(app, "1-transactions")

        let add = app.buttons["addTransaction"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: add)
        waitForExpectations(timeout: 15)
        snapshot(app, "1b-synced")
        add.tap()
        let amount = app.textFields["0,00"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        // The sheet may still be animating in; wait until the field owns the keyboard.
        if !(amount.value(forKey: "hasKeyboardFocus") as? Bool ?? false) {
            sleep(1)
            amount.tap()
        }
        amount.typeText("4,20")
        snapshot(app, "2-form")
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.staticTexts["−4,20 €"].waitForExistence(timeout: 10))
        snapshot(app, "3-after-add")

        for (index, tab) in ["Сводка", "Справочники", "Настройки"].enumerated() {
            tabBar.buttons[tab].tap()
            sleep(3)
            snapshot(app, "\(index + 4)-\(tab)")
        }
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
