import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

@Test func titleEditPersistsWithOutboxAndRejectsTrashedCard() async throws {
    let now = DeterministicClock.referenceDate
    let repository = try await InMemoryPetalRepository.bootstrapped(now: now)
    let card = try await repository.createCard(title: "Before", now: now)
    let updated = try await repository.updateCardTitle(card.id, title: "After", now: now.addingTimeInterval(1))
    #expect(updated.title == "After")
    #expect(try await repository.card(id: card.id)?.title == "After")
    let changes = try await repository.pendingOutbox()
    #expect(changes.count == 3)
    #expect(try JSONDecoder().decode(Card.self, from: changes.last!.payload).title == "After")
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: now.addingTimeInterval(2))
    await #expect(throws: RepositoryError.cardUnavailable) {
        _ = try await repository.updateCardTitle(card.id, title: "Forbidden", now: now.addingTimeInterval(3))
    }
    #expect(try await repository.card(id: card.id)?.title == "After")
}

@Test func trashedCardRestoresToActiveWithoutStealingInbox() async throws {
    let now = DeterministicClock.referenceDate
    let repository = try await InMemoryPetalRepository.bootstrapped(now: now)
    let card = try await repository.createCard(title: "Restore me", now: now)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: now)
    try await repository.moveCard(card.id, to: .active, replacementInbox: nil, now: now)
    let restored = try #require(await repository.card(id: card.id))
    #expect(restored.status == .active)
    #expect(restored.deletedAt == nil)
    #expect(!restored.isInbox)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).count == 1)
}
