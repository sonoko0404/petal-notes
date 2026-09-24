import XCTest

@MainActor
final class LibraryAndEditorUITests: XCTestCase {
    func testSingleWindowNavigationCreateEditAndMoveAcrossScopes() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.buttons["scope.inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scope.allCards"].exists)
        XCTAssertTrue(app.buttons["scope.archive"].exists)
        XCTAssertTrue(app.buttons["scope.trash"].exists)
        XCTAssertTrue(app.buttons["scope.settings"].exists)
        app.buttons["scope.allCards"].click()
        app.buttons["card.create"].click()
        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Weekend")
        let newLine = app.textFields["editor.newLine"]
        newLine.click()
        newLine.typeText("Pack bag\r")
        XCTAssertTrue(app.buttons["line.kind.todo"].waitForExistence(timeout: 5))
        app.buttons["line.complete"].click()
        XCTAssertTrue(app.buttons["line.incomplete"].exists)
        app.buttons["line.kind.todo"].click()
        app.menuItems["Convert to Text"].click()
        XCTAssertTrue(app.buttons["line.kind.text"].exists)
        newLine.click()
        newLine.typeText("Book ride\r")
        app.buttons["line.kind.todo"].click()
        app.menuItems["Move Up"].click()
        let orderedLines = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'"))
        XCTAssertEqual(orderedLines.element(boundBy: 0).value as? String, "Book ride")
        app.buttons["card.archive"].click()
        app.buttons["scope.archive"].click()
        XCTAssertTrue(app.staticTexts["Weekend"].waitForExistence(timeout: 5))
        app.buttons["card.restore"].click()
        app.buttons["scope.allCards"].click()
        XCTAssertTrue(app.staticTexts["Weekend"].waitForExistence(timeout: 5))
        app.staticTexts["Weekend"].click()
        app.buttons["card.trash"].click()
        app.buttons["scope.trash"].click()
        XCTAssertTrue(app.staticTexts["Weekend"].waitForExistence(timeout: 5))
        app.buttons["card.restore"].click()
    }

    func testSearchShowsSourceScopeLabels() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-sample-cards"]
        app.launch()
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("shared")
        XCTAssertTrue(app.staticTexts["scopeLabel.allCards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scopeLabel.archive"].exists)
    }

    func testFailedDraftShowsRetryAndPersistsAfterRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-sample-cards", "-ui-fail-next-save"]
        app.launch()
        XCTAssertTrue(app.buttons["scope.allCards"].waitForExistence(timeout: 5))
        app.buttons["scope.allCards"].click()
        app.staticTexts["Active sample"].click()
        let line = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.click()
        line.typeText(" revised")
        XCTAssertTrue(app.buttons["editor.retry"].waitForExistence(timeout: 5))
        app.buttons["editor.retry"].click()
        XCTAssertFalse(app.buttons["editor.retry"].waitForExistence(timeout: 2))
        app.buttons["scope.inbox"].click()
        app.buttons["scope.allCards"].click()
        app.staticTexts["Active sample"].click()
        let persisted = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'")).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertTrue((persisted.value as? String)?.contains("revised") == true)
    }
}
