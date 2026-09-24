import XCTest
import PetalPersistence

/// Only runnable on a Mac whose XCTest automation has initialized successfully.
/// Cold launch includes process creation through an accepted edit; hot focus uses
/// the shipped first-responder measurement. No UI latency stub participates.
@MainActor final class PerformanceUITests: XCTestCase {
    func testColdLaunchEditableAndHotCaptureFocusOnFiveThousandRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetalUIPerf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await PerformanceFixture.make(root: root)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-enable-hotkey", "-AppleKeyboardUIMode", "3"]
        app.launchEnvironment["PETAL_UI_TEST_STORE"] = root.path
        let clock = ContinuousClock()
        let start = clock.now
        app.launch()
        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        for _ in 0..<80 {
            if keyboardFocusMatches(title) { break }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(keyboardFocusMatches(title))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Editable")
        XCTAssertEqual(title.value as? String, "Editable")
        let duration = start.duration(to: clock.now)
        let cold = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        print("PETAL_PERF cold_editable_ms=\(cold)")
        // One unmeasured hot-capture warmup, dismissed before the timed invocation.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.textViews["quickCapture.text"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.textViews["quickCapture.text"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        app.typeKey("n", modifierFlags: [.command, .option])
        let capture = app.textViews["quickCapture.text"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        app.typeText("Focused")
        XCTAssertEqual(capture.value as? String, "Focused")
        let value = app.staticTexts["quickCapture.focusLatencyMs"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        let hot = try XCTUnwrap(Double(value.label))
        XCTAssertGreaterThanOrEqual(hot, 0)
        print("PETAL_PERF hot_focus_ms=\(hot)")
        // Thresholds are evaluated over three consecutive Release runs by release-gates.py.
        app.terminate()
    }
}
