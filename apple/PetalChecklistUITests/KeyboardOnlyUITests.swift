import XCTest
import AppKit
import ApplicationServices

/// macOS XCTest does not expose hasFocus. Read the public AX focused-element
/// attribute; never set AX focus or press an AX action in a keyboard-only test.
@MainActor func keyboardFocusMatches(_ element: XCUIElement) -> Bool {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
    let focused = unsafeBitCast(raw, to: AXUIElement.self)
    var identifier: CFTypeRef?
    if !element.identifier.isEmpty,
       AXUIElementCopyAttributeValue(focused, kAXIdentifierAttribute as CFString, &identifier) == .success,
       identifier as? String == element.identifier { return true }
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return false }
    return element.frame.insetBy(dx: -2, dy: -2).contains(CGRect(origin: point, size: dimensions))
}

/// Every action is a key event. Looking up an element never substitutes a pointer action.
@MainActor final class KeyboardOnlyUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-sample-cards", "-AppleLanguages", "(en)", "-AppleKeyboardUIMode", "3"]
        app.launch()
        XCTAssertTrue(app.buttons["scope.inbox"].waitForExistence(timeout: 10))
        return app
    }
    private func focus(_ element: XCUIElement, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<100 {
            if keyboardFocusMatches(element) { return }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTFail("Element is not reachable by Tab: \(element.identifier)", file: file, line: line)
    }
    private func activate(_ element: XCUIElement, app: XCUIApplication) {
        focus(element, app: app)
        app.typeKey(.space, modifierFlags: [])
    }
    private func replace(_ element: XCUIElement, with text: String, app: XCUIApplication) {
        focus(element, app: app)
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }
    func testCreateAddConvertCompleteReorderSearchArchiveTrashRestoreAndReminder() {
        let app = launch()
        activate(app.buttons["card.create"], app: app)
        replace(app.textFields["editor.title"], with: "Keyboard card", app: app)
        replace(app.textFields["editor.newLine"], with: "First todo", app: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["line.complete"].waitForExistence(timeout: 5))
        activate(app.buttons["line.complete"].firstMatch, app: app)
        XCTAssertTrue(app.buttons["line.incomplete"].waitForExistence(timeout: 5))
        activate(app.buttons["line.kind.todo"].firstMatch, app: app)
        app.typeKey("c", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["line.kind.text"].waitForExistence(timeout: 5))
        activate(app.buttons["line.kind.text"].firstMatch, app: app)
        app.typeKey("c", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["line.kind.todo"].waitForExistence(timeout: 5))
        replace(app.textFields["editor.newLine"], with: "Second todo", app: app)
        app.typeKey(.return, modifierFlags: [])
        let lines = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'"))
        XCTAssertTrue(lines.element(boundBy: 1).waitForExistence(timeout: 5))
        focus(lines.element(boundBy: 1), app: app)
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Second todo'"), object: lines.element(boundBy: 0))
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        activate(app.buttons["line.kind.todo"].firstMatch, app: app)
        app.typeKey("r", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["reminder.save"].waitForExistence(timeout: 5))
        // Toggle Enable off using keyboard to exercise durable reminder editing without an OS permission prompt.
        activate(app.checkBoxes["Enable Reminder"], app: app)
        XCTAssertEqual(app.checkBoxes["Enable Reminder"].value as? String, "0")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["reminder.save"].exists)
        activate(app.buttons["Close"], app: app)
        activate(app.buttons["line.kind.todo"].firstMatch, app: app)
        app.typeKey("r", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.checkBoxes["Enable Reminder"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.checkBoxes["Enable Reminder"].value as? String, "0")
        activate(app.buttons["Close"], app: app)
        activate(app.buttons["card.archive"], app: app)
        activate(app.buttons["scope.archive"], app: app)
        XCTAssertTrue(app.buttons["Keyboard card"].waitForExistence(timeout: 5))
        activate(app.buttons["card.restore"].firstMatch, app: app)
        activate(app.buttons["scope.allCards"], app: app)
        activate(app.buttons["Keyboard card"], app: app)
        activate(app.buttons["card.trash"], app: app)
        activate(app.buttons["scope.trash"], app: app)
        activate(app.buttons["Keyboard card"], app: app)
        XCTAssertTrue(app.buttons["editor.restore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["editor.title"].exists)
        activate(app.buttons["editor.restore"], app: app)
        replace(app.textFields["library.search"], with: "Second todo", app: app)
        XCTAssertTrue(app.staticTexts["Second todo"].waitForExistence(timeout: 5))
    }

    func testSettingsExportImportRestoreAndDeleteAllUsingKeyboard() throws {
        let app = launch()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetalKeyboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("backup.json")
        activate(app.buttons["scope.settings"], app: app)
        activate(app.buttons["transfer.exportJSON"], app: app)
        choosePath(backup.path, app: app)
        XCTAssertTrue(app.staticTexts["transfer.success"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(try Data(contentsOf: backup).count, 0)
        activate(app.buttons["transfer.restoreJSON"], app: app)
        choosePath(backup.path, app: app)
        activate(app.buttons["Replace Data"], app: app)
        XCTAssertTrue(app.staticTexts["transfer.success"].waitForExistence(timeout: 5))
        let windows = root.appendingPathComponent("windows.json")
        try Data(#"{"SchemaVersion":1,"Notes":[{"Id":"4dbfd594-1ee5-472b-8a00-687675b485f7","Title":"Keyboard imported","Body":"Imported through keys"}]}"#.utf8).write(to: windows)
        activate(app.buttons["transfer.importWindows"], app: app)
        choosePath(windows.path, app: app)
        let beforeImport = root.appendingPathComponent("before-import.json")
        choosePath(beforeImport.path, app: app)
        XCTAssertTrue(app.staticTexts["transfer.success"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(try Data(contentsOf: beforeImport).count, 0)
        activate(app.buttons["scope.allCards"], app: app)
        XCTAssertTrue(app.buttons["Keyboard imported"].waitForExistence(timeout: 5))
        activate(app.buttons["scope.settings"], app: app)
        activate(app.buttons["transfer.exportMarkdown"], app: app)
        choosePath(root.path, app: app)
        XCTAssertTrue(app.staticTexts["transfer.success"].waitForExistence(timeout: 5))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("Petal Markdown Export"))
        activate(app.buttons["settings.resetEntry"], app: app)
        let confirmation = app.textFields["settings.resetConfirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.resetConfirm"].isEnabled)
        replace(confirmation, with: "Petal Checklist", app: app)
        XCTAssertTrue(app.buttons["settings.resetConfirm"].isEnabled)
        activate(app.buttons["settings.resetConfirm"], app: app)
        XCTAssertTrue(app.textFields["editor.newLine"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'")).count, 0)
    }
    private func choosePath(_ path: String, app: XCUIApplication) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
    }
}
