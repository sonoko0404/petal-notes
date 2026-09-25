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
        let orderedLines = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'"))
        let secondLine = orderedLines.element(boundBy: 1)
        secondLine.click()
        secondLine.typeKey(.upArrow, modifierFlags: [.command, .option])
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
        app.staticTexts["Weekend"].click()
        XCTAssertTrue(app.buttons["editor.restore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["editor.title"].exists)
        app.buttons["editor.restore"].click()
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
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["editor.retry"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 2), .completed)
        app.buttons["scope.inbox"].click()
        app.buttons["scope.allCards"].click()
        app.staticTexts["Active sample"].click()
        let persisted = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'line.text.'")).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertTrue((persisted.value as? String)?.contains("revised") == true)
    }

    func testInboxMoveOffersExplicitReplacementChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-sample-cards", "-ui-extra-active-candidate"]
        app.launch()
        XCTAssertTrue(app.buttons["card.archive"].waitForExistence(timeout: 5))
        app.buttons["card.archive"].click()
        let chooser = app.dialogs.firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        XCTAssertTrue(chooser.staticTexts["Choose New Inbox"].exists)
        XCTAssertTrue(chooser.buttons["Active sample"].exists)
        XCTAssertTrue(chooser.buttons["Other active sample"].exists)
        XCTAssertTrue(app.buttons["card.archive"].exists, "The original Inbox must remain active before a choice")
        chooser.buttons["Other active sample"].click()
        app.buttons["scope.inbox"].click()
        XCTAssertTrue(app.buttons["Other active sample"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Active sample"].exists)
    }
}
