import XCTest

final class OnboardingAndSettingsUITests: XCTestCase {
    @MainActor func testFreshOnboardingAndSupportAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.finish"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1. Add a Widget"].exists)
        XCTAssertTrue(app.staticTexts["2. Complete a Todo"].exists)
        XCTAssertTrue(app.staticTexts["3. Create a Card"].exists)
        app.buttons["onboarding.finish"].click()
        app.buttons["scope.settings"].click()
        XCTAssertTrue(app.buttons["settings.help"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.privacy"].exists)
        app.buttons["settings.resetEntry"].click()
        let confirm = app.buttons["settings.resetConfirm"]
        XCTAssertFalse(confirm.isEnabled)
        app.textFields["settings.resetConfirmation"].click()
        app.textFields["settings.resetConfirmation"].typeText("wrong name")
        XCTAssertFalse(confirm.isEnabled)
    }
}
