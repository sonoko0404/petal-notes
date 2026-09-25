import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class CardLibraryModelTests: XCTestCase {
    func testScopesSearchAndRestoreShowSourceStatus() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let active = try await repository.createCard(title: "Work", now: .now)
        let archived = try await repository.createCard(title: "Old", now: .now)
        _ = try await repository.addLine(NewLineDraft(cardID: archived.id, kind: .text, text: "shared clue"), now: .now)
        _ = try await repository.addLine(NewLineDraft(cardID: active.id, kind: .todo, text: "shared todo"), now: .now)
        try await repository.moveCard(archived.id, to: .archived, replacementInbox: nil, now: .now)
        let model = CardLibraryModel(repository: repository)
        try await model.show(.archive)
        XCTAssertEqual(model.cards.map(\.id), [archived.id])
        try await model.search("shared")
        XCTAssertEqual(Set(model.searchResults.map(\.scope)), Set([.allCards, .archive]))
        try await model.show(.archive)
        try await model.restore(archived.id)
        let restored = try await repository.card(id: archived.id)
        XCTAssertEqual(restored?.status, .active)
    }

    func testStaleSearchCannotReplaceNewerResults() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        _ = try await base.createCard(title: "first result", now: .now)
        _ = try await base.createCard(title: "second result", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardLibraryModel(repository: repository)
        repository.searchGate.pauseNext()
        let first = Task { try await model.search("first") }
        await repository.searchGate.waitUntilEntered()
        try await model.search("second")
        repository.searchGate.resume()
        try await first.value
        XCTAssertEqual(model.query, "second")
        XCTAssertEqual(model.searchResults.map(\.result.title), ["second result"])
    }

    func testMovingSearchHitRefreshesResultAndKeepsQuery() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "shared card", now: .now)
        let model = CardLibraryModel(repository: repository)
        try await model.show(.allCards)
        try await model.search("shared")
        try await model.move(card.id, to: .archived)
        XCTAssertEqual(model.query, "shared")
        XCTAssertEqual(model.searchResults.map(\.scope), [.archive])
    }

    func testInboxMoveUsesExplicitCandidateWithoutCreatingExtraCard() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let active = try await repository.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let a = try await repository.createCard(title: "A", now: .now)
        let b = try await repository.createCard(title: "B", now: .now)
        let model = CardLibraryModel(repository: repository)
        let choices = try await model.replacementCandidates(for: inbox.id)
        XCTAssertEqual(Set(choices.map(\.id)), Set([a.id, b.id]))
        try await model.move(inbox.id, to: .archived, replacementInbox: b.id)
        let all = try await repository.cards(scope: .all)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first(where: { $0.isInbox })?.id, b.id)
    }

    func testSearchFailureKeepsQueryAndRetryShowsResults() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        _ = try await base.createCard(title: "find me", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardLibraryModel(repository: repository)
        repository.failNextSearch = true
        do { try await model.search("find") } catch { }
        XCTAssertEqual(model.query, "find")
        XCTAssertNotNil(model.errorMessage)
        await model.retryQuery()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.searchResults.map(\.result.title), ["find me"])
    }

    func testCommittedCreateWithRefreshFailureDoesNotCreateAgainOnRetry() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let repository = ControlledRepository(base: base)
        let model = CardLibraryModel(repository: repository)
        repository.failNextCards = true
        let created = try await model.createCard(title: "One")
        XCTAssertNotNil(model.errorMessage)
        await model.retryQuery()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.cards.filter { $0.id == created.id }.count, 1)
        let all = try await base.cards(scope: .all)
        XCTAssertEqual(all.filter { $0.title == "One" }.count, 1)
    }

    func testCommittedMoveWithRefreshFailureCanRefreshWithoutReapplyingMove() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Move", now: .now)
        let repository = ControlledRepository(base: base)
        let model = CardLibraryModel(repository: repository)
        try await model.show(.archive)
        repository.failNextCards = true
        try await model.move(card.id, to: .archived)
        XCTAssertNotNil(model.errorMessage)
        await model.retryQuery()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.cards.map(\.id), [card.id])
    }

    func testSearchLabelsInboxAndTrashSources() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let inbox = try await repository.cards(scope: .active).first { $0.isInbox }
        let inboxID = try XCTUnwrap(inbox?.id)
        _ = try await repository.addLine(NewLineDraft(cardID: inboxID, kind: .todo, text: "cross"), now: .now)
        let trashed = try await repository.createCard(title: "cross archive", now: .now)
        try await repository.moveCard(trashed.id, to: .trashed, replacementInbox: nil, now: .now)
        let model = CardLibraryModel(repository: repository)
        try await model.search("cross")
        XCTAssertEqual(Set(model.searchResults.map(\.scope)), Set([.inbox, .trash]))
    }
}
