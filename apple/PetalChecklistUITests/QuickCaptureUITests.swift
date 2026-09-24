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
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        app.buttons["scope.inbox"].click()
        let inbox = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card.select.'")).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()
        let fields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'"))
        XCTAssertTrue(fields.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(fields.element(boundBy: 0).value as? String, "Buy tea")
        XCTAssertEqual(fields.element(boundBy: 1).value as? String, "Call mom")
    }

    func testHotKeyInvocationFocusLatencyIsRecorded() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-enable-hotkey"]
        app.launch()
        XCTAssertTrue(app.buttons["scope.inbox"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: [.option, .command])
        let editor = app.textViews["quickCapture.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("a")
        XCTAssertEqual(editor.value as? String, "a")
        let measurement = app.staticTexts["quickCapture.focusLatencyMs"]
        XCTAssertTrue(measurement.waitForExistence(timeout: 5))
        guard let milliseconds = Double(measurement.label) else {
            XCTFail("Focus measurement must be numeric")
            return
        }
        XCTAssertLessThanOrEqual(milliseconds, 300, "Production hotkey-to-first-responder measurement exceeded 300 ms")
    }
}
