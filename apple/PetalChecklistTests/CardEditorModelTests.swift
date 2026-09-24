import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
import SwiftUI
@testable import PetalChecklist

@MainActor
final class CardEditorModelTests: XCTestCase {
    func testMixedLinesDefaultToTodoConvertCompleteAndShareReorderPath() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Today", now: .now)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        try await model.addLine(text: "First")
        try await model.addLine(text: "Second")
        XCTAssertEqual(model.lines.map(\.kind), [.todo, .todo])
        try await model.convert(lineID: model.lines[0].id, to: .text)
        XCTAssertEqual(model.lines.map(\.kind), [.text, .todo])
        try await model.setCompleted(lineID: model.lines[1].id, completed: true)
        XCTAssertTrue(model.lines[1].isCompleted)
        try await model.move(lineID: model.lines[1].id, direction: .up)
        XCTAssertEqual(model.lines.map(\.text), ["Second", "First"])
        try await model.reorder(orderedLineIDs: model.lines.map(\.id).reversed())
        let persistedOrder = try await repository.lines(cardID: card.id).map(\.text)
        XCTAssertEqual(persistedOrder, ["First", "Second"])
    }

    func testDebouncePersistsTitleAndTextAndFlushesBeforeLeaving() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Old", now: .now)
        let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Old line"), now: .now)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        model.editTitle("New")
        model.editText(lineID: line.id, text: "New line")
        let beforeTitle = try await repository.card(id: card.id)?.title
        XCTAssertEqual(beforeTitle, "Old")
        let flushed = await model.flushPending()
        XCTAssertTrue(flushed)
        let afterTitle = try await repository.card(id: card.id)?.title
        let afterLine = try await repository.lines(cardID: card.id).first?.text
        XCTAssertEqual(afterTitle, "New")
        XCTAssertEqual(afterLine, "New line")
        XCTAssertEqual(model.saveState, .saved)
    }

    func testDebounceCancelsEarlierTextAndCommitsLatestAfterFourHundredMilliseconds() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Card", now: .now)
        let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Old"), now: .now)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        model.editText(lineID: line.id, text: "First")
        try await Task.sleep(for: .milliseconds(250))
        model.editText(lineID: line.id, text: "Final")
        try await Task.sleep(for: .milliseconds(250))
        let before = try await repository.lines(cardID: card.id).first?.text
        XCTAssertEqual(before, "Old")
        try await Task.sleep(for: .milliseconds(250))
        let after = try await repository.lines(cardID: card.id).first?.text
        XCTAssertEqual(after, "Final")
    }

    func testFailedSaveRetainsDraftAndRetryPersistsIt() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let setup = SwiftDataPetalRepository(container: store)
        try await setup.bootstrap(now: .now)
        let card = try await setup.createCard(title: "Card", now: .now)
        let line = try await setup.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Old"), now: .now)
        let repository = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        model.editText(lineID: line.id, text: "Draft")
        let first = await model.flushPending()
        XCTAssertFalse(first)
        XCTAssertEqual(model.unsavedText[line.id], "Draft")
        let beforeRetry = try await setup.lines(cardID: card.id).first?.text
        XCTAssertEqual(beforeRetry, "Old")
        let retry = await model.retry()
        XCTAssertTrue(retry)
        let afterRetry = try await setup.lines(cardID: card.id).first?.text
        XCTAssertEqual(afterRetry, "Draft")
        XCTAssertTrue(model.unsavedText.isEmpty)
    }

    func testFlushDrainsEditArrivingDuringSuspendedWrite() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Old", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        repository.titleGate.pauseNext()
        model.editTitle("First")
        let flush = Task { await model.flushPending() }
        await repository.titleGate.waitUntilEntered()
        model.editTitle("Latest")
        repository.titleGate.resume()
        let flushed = await flush.value
        XCTAssertTrue(flushed)
        let persisted = try await base.card(id: card.id)
        XCTAssertEqual(persisted?.title, "Latest")
        XCTAssertNil(model.unsavedTitle)
    }

    func testNewLineDraftSurvivesInFlightEditAndRejectsDuplicateSubmission() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Card", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        model.editNewLine("First")
        repository.addGate.pauseNext()
        let submission = Task { try await model.submitNewLine() }
        await repository.addGate.waitUntilEntered()
        model.editNewLine("Second")
        let duplicate = try await model.submitNewLine()
        XCTAssertFalse(duplicate)
        repository.addGate.resume()
        let submitted = try await submission.value
        XCTAssertTrue(submitted)
        XCTAssertEqual(model.newLineDraft, "Second")
        let firstLines = try await base.lines(cardID: card.id).map(\.text)
        XCTAssertEqual(firstLines, ["First"])
        let secondSubmitted = try await model.submitNewLine()
        XCTAssertTrue(secondSubmitted)
        let bothLines = try await base.lines(cardID: card.id).map(\.text)
        XCTAssertEqual(bothLines, ["First", "Second"])
    }

    func testNewLineSubmissionKeepsNewRevisionEvenWhenTextReturnsToSameValue() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Card", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        model.editNewLine("Same")
        repository.addGate.pauseNext()
        let submission = Task { try await model.submitNewLine() }
        await repository.addGate.waitUntilEntered()
        model.editNewLine("Changed")
        model.editNewLine("Same")
        repository.addGate.resume()
        _ = try await submission.value
        XCTAssertEqual(model.newLineDraft, "Same")
    }

    func testTrashedCardLoadsReadOnlyAndCanBeRestored() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Trash me", now: .now)
        try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: .now)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        XCTAssertTrue(model.isReadOnly)
        model.editTitle("Should not save")
        XCTAssertNil(model.unsavedTitle)
        try await repository.moveCard(card.id, to: .active, replacementInbox: nil, now: .now)
        try await model.load()
        XCTAssertFalse(model.isReadOnly)
    }

    func testMoveCommandIgnoresHorizontalDirections() {
        XCTAssertEqual(CardLineRow.moveDirection(for: .up), .up)
        XCTAssertEqual(CardLineRow.moveDirection(for: .down), .down)
        XCTAssertNil(CardLineRow.moveDirection(for: .left))
        XCTAssertNil(CardLineRow.moveDirection(for: .right))
    }

    func testMoveAtOrderBoundaryDoesNotWriteOrChangeOrder() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Card", now: .now)
        let model = CardEditorModel(cardID: card.id, repository: repository)
        try await model.load()
        try await model.addLine(text: "First")
        try await model.addLine(text: "Last")
        let beforeCount = try await repository.pendingOutboxCount()
        try await model.move(lineID: model.lines[0].id, direction: .up)
        try await model.move(lineID: model.lines[1].id, direction: .down)
        XCTAssertEqual(model.lines.map(\.text), ["First", "Last"])
        let afterCount = try await repository.pendingOutboxCount()
        XCTAssertEqual(afterCount, beforeCount)
    }
}
