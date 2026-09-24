import XCTest

@MainActor
final class QuickCaptureUITests: XCTestCase {
    func testLaunchCaptureMultilineSubmitAndVerifyInbox() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-open-quick-capture"]
        app.launch()
        let editor = app.textViews["quickCapture.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Buy tea")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("Call mom")
        XCTAssertEqual(editor.value as? String, "Buy tea\nCall mom")
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(editor.waitForExistence(timeout: 1))
        app.buttons["scope.inbox"].click()
        XCTAssertTrue(app.staticTexts["Buy tea"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Call mom"].exists)
    }

    func testHotKeyInvocationFocusLatencyIsRecorded() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-enable-hotkey"]
        app.launch()
        XCTAssertTrue(app.buttons["scope.inbox"].waitForExistence(timeout: 5))
        let invocation = ProcessInfo.processInfo.systemUptime
        app.typeKey("n", modifierFlags: [.option, .command])
        let editor = app.textViews["quickCapture.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("a")
        XCTAssertEqual(editor.value as? String, "a")
        let observed = ProcessInfo.processInfo.systemUptime - invocation
        print("Quick capture hotkey to focused editor, including XCTest automation: \(observed) seconds")
    }
}
