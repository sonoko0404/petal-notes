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
        repository.failNextCapture = true
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
        repository.captureGate.pauseNext()
        let first = Task { await model.submit() }
        await repository.captureGate.waitUntilEntered()
        model.edit("Second")
        await model.submit()
        repository.captureGate.resume()
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

    func testMarkedTextReturnAndEscapePassToAppKitInputMethod() {
        let editor = CaptureNSTextView()
        var commands: [QuickCaptureKeyAction] = []
        var passed = 0
        editor.onKey = { commands.append($0) }
        for code: UInt16 in [36, 53] {
            editor.dispatchKey(keyCode: code, shift: false, markedText: true,
                               passThrough: { passed += 1 }, insertNewline: { XCTFail("Marked text must not insert directly") })
        }
        XCTAssertEqual(passed, 2)
        XCTAssertTrue(commands.isEmpty)
        editor.dispatchKey(keyCode: 36, shift: false, markedText: false,
                           passThrough: { XCTFail("Plain Return must submit") }, insertNewline: { })
        editor.dispatchKey(keyCode: 53, shift: false, markedText: false,
                           passThrough: { XCTFail("Plain Escape must cancel") }, insertNewline: { })
        XCTAssertEqual(commands, [.submit, .cancel])
    }

    func testFailedBatchAfterEditSubmitsOnlyCurrentDraftOnce() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Target", now: .now)
        let repository = ControlledRepository(base: base)
        repository.failNextCapture = true
        let model = QuickCaptureModel(repository: repository, target: .card(card.id))
        model.edit("One typo\nTwo")
        await model.submit()
        let beforeLines = try await base.lines(cardID: card.id)
        XCTAssertEqual(beforeLines.count, 0)
        model.edit("One\nTwo")
        await model.submit()
        XCTAssertTrue(model.shouldClose)
        let lines = try await base.lines(cardID: card.id)
        XCTAssertEqual(lines.map(\.text), ["One", "Two"])
    }

    func testArchiveBetweenResolutionAndBatchRejectsEverything() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Target", now: .now)
        let repository = ControlledRepository(base: base)
        repository.archiveBeforeCapture = true
        let model = QuickCaptureModel(repository: repository, target: .card(card.id))
        model.edit("One\nTwo")
        let before = try await base.pendingOutboxCount()
        await model.submit()
        XCTAssertFalse(model.shouldClose)
        XCTAssertEqual(model.text, "One\nTwo")
        let lines = try await base.lines(cardID: card.id)
        XCTAssertTrue(lines.isEmpty)
        let archived = try await base.card(id: card.id)
        XCTAssertEqual(archived?.status, .archived)
        let after = try await base.pendingOutboxCount()
        XCTAssertEqual(after, before + 1)
    }
}
