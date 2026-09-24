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
}
