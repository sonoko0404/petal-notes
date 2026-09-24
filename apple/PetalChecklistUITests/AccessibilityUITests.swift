import XCTest

@MainActor final class AccessibilityUITests: XCTestCase {
    func testAppControlsExposeLabelsStatesAndKeyboardFocusInBothLanguages() throws {
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))", "-AppleKeyboardUIMode", "3"]
            app.launch()
            let create = app.buttons["card.create"]
            XCTAssertTrue(create.waitForExistence(timeout: 10))
            XCTAssertFalse(create.label.isEmpty)
            XCTAssertFalse(create.label.hasPrefix("ui."))
            XCTAssertGreaterThanOrEqual(create.frame.height, 28)
            for _ in 0..<80 {
                if keyboardFocusMatches(create) { break }
                app.typeKey(.tab, modifierFlags: [])
            }
            XCTAssertTrue(keyboardFocusMatches(create))
            app.typeKey(.space, modifierFlags: [])
            XCTAssertTrue(app.textFields["editor.title"].waitForExistence(timeout: 5))
            if #available(macOS 14.0, *) {
                try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription])
            }
            app.terminate()
        }
    }
}
