import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class QuickCaptureModelTests: XCTestCase {
    func testFailurePreservesExactMultilineDraftAndRetryCreatesTodoLines() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let repository = ControlledRepository(base: base)
        repository.failNextAdd = true
        let model = QuickCaptureModel(repository: repository, target: .inbox)
        model.edit("  Buy tea  \nCall mom\n")
        await model.submit()
        XCTAssertEqual(model.text, "  Buy tea  \nCall mom\n")
        XCTAssertFalse(model.shouldClose)
        XCTAssertNotNil(model.errorMessage)
        await model.submit()
        XCTAssertTrue(model.shouldClose)
        let lines = try await base.lines(cardID: inbox.id)
        XCTAssertEqual(lines.map(\.text), ["  Buy tea  ", "Call mom"])
        XCTAssertEqual(lines.map(\.kind), [.todo, .todo])
    }

    func testSuppliedActiveCardWinsAndUnavailableCardFallsBackVisibly() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "Target", now: .now)
        let active = try await repository.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let valid = QuickCaptureModel(repository: repository, target: .card(card.id))
        valid.edit("For target")
        await valid.submit()
        let targetLines = try await repository.lines(cardID: card.id)
        XCTAssertEqual(targetLines.map(\.text), ["For target"])
        let unavailable = QuickCaptureModel(repository: repository, target: .card(CardID(rawValue: UUID())))
        unavailable.edit("Fallback")
        await unavailable.submit()
        XCTAssertFalse(unavailable.shouldClose)
        XCTAssertNotNil(unavailable.targetNotice)
        XCTAssertEqual(unavailable.text, "Fallback")
        await unavailable.submit()
        XCTAssertTrue(unavailable.shouldClose)
        let inboxLines = try await repository.lines(cardID: inbox.id)
        XCTAssertEqual(inboxLines.map(\.text), ["Fallback"])
    }

    func testDuplicateSubmissionAndInFlightEditDoNotLoseNewDraft() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let repository = ControlledRepository(base: base)
        let model = QuickCaptureModel(repository: repository, target: .inbox)
        model.edit("First")
        repository.addGate.pauseNext()
        let first = Task { await model.submit() }
        await repository.addGate.waitUntilEntered()
        model.edit("Second")
        await model.submit()
        repository.addGate.resume()
        await first.value
        XCTAssertFalse(model.shouldClose)
        XCTAssertEqual(model.text, "Second")
        let firstLines = try await base.lines(cardID: inbox.id)
        XCTAssertEqual(firstLines.map(\.text), ["First"])
        await model.submit()
        let finalLines = try await base.lines(cardID: inbox.id)
        XCTAssertEqual(finalLines.map(\.text), ["First", "Second"])
    }

    func testKeyboardRoutingKeepsShiftReturnForNewline() {
        XCTAssertEqual(QuickCaptureKeyAction.action(keyCode: 36, shift: false), .submit)
        XCTAssertEqual(QuickCaptureKeyAction.action(keyCode: 36, shift: true), .newline)
        XCTAssertEqual(QuickCaptureKeyAction.action(keyCode: 53, shift: false), .cancel)
    }

    func testPartialSaveNeverMovesRemainingLinesToAnotherCard() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Target", now: .now)
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let repository = ControlledRepository(base: base)
        repository.failOnAddNumber = 2
        let model = QuickCaptureModel(repository: repository, target: .card(card.id))
        model.edit("One\nTwo")
        await model.submit()
        let firstLines = try await base.lines(cardID: card.id)
        XCTAssertEqual(firstLines.map(\.text), ["One"])
        try await base.moveCard(card.id, to: .archived, replacementInbox: nil, now: .now)
        await model.submit()
        await model.submit()
        XCTAssertFalse(model.shouldClose)
        XCTAssertEqual(model.text, "One\nTwo")
        let inboxLines = try await base.lines(cardID: inbox.id)
        XCTAssertTrue(inboxLines.isEmpty)
    }
}
