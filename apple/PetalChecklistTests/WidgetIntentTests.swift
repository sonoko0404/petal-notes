import XCTest
import AppIntents
import PetalCore
import PetalPersistence
import PetalTestSupport

private actor ReloadRecorder: WidgetReloading {
    var kinds: [String] = []
    func reload(kind: String) { kinds.append(kind) }
}

private struct FailedAction: WidgetTodoAction {
    let error: RepositoryError
    func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws { throw error }
}

@MainActor
final class WidgetIntentTests: XCTestCase {
    func testRowControlsUseFinalStateAndTextOpensTheSameCard() {
        let card = CardID(rawValue: UUID())
        let id = LineID(rawValue: UUID())
        for completed in [false, true] {
            let row = WidgetLine(id: id, kind: .todo, text: "Full accessibility text", isCompleted: completed)
            guard case .todo(let intent) = WidgetRowControl(line: row, cardID: card) else { return XCTFail("Expected toggle") }
            XCTAssertEqual(intent.line.id, id.rawValue)
            XCTAssertEqual(intent.completed, !completed)
        }
        let text = WidgetLine(id: id, kind: .text, text: "Note", isCompleted: false)
        guard case .link(let url) = WidgetRowControl(line: text, cardID: card) else { return XCTFail("Expected link") }
        XCTAssertEqual(PetalDeepLink(url: url), .card(card))
    }

    func testOpenAndQuickAddIntentsDeliverExactURLsIncludingColdLaunch() async throws {
        let requests = PetalNavigationRequests()
        let id = CardID(rawValue: UUID(uuidString: "20F46FAB-23E3-4914-B0E0-5BE0CB39045F")!)
        var delivered: [URL] = []
        await OpenCardIntent(cardID: id).perform(navigation: requests)
        XCTAssertTrue(delivered.isEmpty)
        await requests.install { delivered.append($0) }
        await QuickAddIntent(cardID: id).perform(navigation: requests)
        XCTAssertEqual(delivered.map(\.absoluteString), [
            "petal://card/20F46FAB-23E3-4914-B0E0-5BE0CB39045F",
            "petal://quick-add/20F46FAB-23E3-4914-B0E0-5BE0CB39045F"])
        XCTAssertTrue(OpenCardIntent.openAppWhenRun)
        XCTAssertTrue(QuickAddIntent.openAppWhenRun)
    }

    func testIntendedStateIsIdempotentAndUsesInjectedClock() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let original = try await f.repository.lines(cardID: f.fixtureCardID)
        let line = try XCTUnwrap(original.first)
        let reload = ReloadRecorder()
        let intent = ToggleTodoIntent(lineID: line.id, completed: true)
        let now = DeterministicClock.referenceDate.addingTimeInterval(90)
        let before = try await f.repository.pendingOutboxCount()
        for _ in 0..<2 {
            let result = await intent.perform(action: RepositoryWidgetTodoAction(repository: f.repository), reloader: reload, clock: { now })
            XCTAssertEqual(result, .success)
        }
        let lines = try await f.repository.lines(cardID: f.fixtureCardID)
        XCTAssertEqual(lines.first?.completedAt, now)
        XCTAssertEqual(lines.first?.isCompleted, true)
        let after = try await f.repository.pendingOutboxCount()
        XCTAssertEqual(after, before + 1)
        let kinds = await reload.kinds
        XCTAssertEqual(kinds, [ChecklistWidget.kind, ChecklistWidget.kind])
    }

    func testFailuresHaveSafeResultsAndAlwaysReload() async {
        for (error, expected) in [(RepositoryError.lineUnavailable, WidgetIntentOutcome.contentUnavailable),
            (.cardUnavailable, .contentUnavailable), (.appGroupUnavailable, .saveFailed),
            (.unsupportedSchema(999), .saveFailed), (.injectedFailure, .saveFailed)] {
            let reload = ReloadRecorder()
            let result = await ToggleTodoIntent(lineID: LineID(rawValue: UUID()), completed: true)
                .perform(action: FailedAction(error: error), reloader: reload, clock: { .now })
            XCTAssertEqual(result, expected)
            let kinds = await reload.kinds
            XCTAssertEqual(kinds, [ChecklistWidget.kind])
        }
    }

    func testFailedTransactionDoesNotChangeLineOrOutboxAndReloads() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataPetalRepository(container: store)
        try await repository.bootstrap(now: .now)
        let cards = try await repository.cards(scope: .active)
        let card = try XCTUnwrap(cards.first)
        let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "private"), now: .now)
        let before = try await repository.pendingOutboxCount()
        let reload = ReloadRecorder()
        let result = await ToggleTodoIntent(lineID: line.id, completed: true).perform(
            action: RepositoryWidgetTodoAction(repository: SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)),
            reloader: reload, clock: { .now })
        XCTAssertEqual(result, .saveFailed)
        let after = try await repository.pendingOutboxCount()
        let lines = try await repository.lines(cardID: card.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(lines, [line])
        let kinds = await reload.kinds
        XCTAssertEqual(kinds, [ChecklistWidget.kind])
    }

    func testDeletedLineIsUnavailableAndReloadsWithoutWriting() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let before = try await repository.pendingOutboxCount()
        let reload = ReloadRecorder()
        let result = await ToggleTodoIntent(lineID: LineID(rawValue: UUID()), completed: true)
            .perform(action: RepositoryWidgetTodoAction(repository: repository), reloader: reload,
                clock: { DeterministicClock.referenceDate })
        XCTAssertEqual(result, .contentUnavailable)
        let kinds = await reload.kinds
        XCTAssertEqual(kinds, [ChecklistWidget.kind])
        let after = try await repository.pendingOutboxCount()
        XCTAssertEqual(after, before)
    }
}
