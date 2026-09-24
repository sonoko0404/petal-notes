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

@Test func unchangedTitleDoesNotJournalAndFailedTitleRollsBack() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    try await repository.bootstrap(now: .now)
    let card = try await repository.createCard(title: "Stable", now: .now)
    let beforeCount = try await repository.pendingOutboxCount()
    let same = try await repository.updateCardTitle(card.id, title: "Stable", now: .now)
    #expect(same.revision == card.revision)
    #expect(try await repository.pendingOutboxCount() == beforeCount)
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        _ = try await failing.updateCardTitle(card.id, title: "Lost", now: .now)
    }
    #expect(try await repository.card(id: card.id)?.title == "Stable")
    #expect(try await repository.pendingOutboxCount() == beforeCount)
}

@Test func movingSoleInboxCreatesReplacementAtomicallyOrRollsBack() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    try await repository.bootstrap(now: .now)
    let inbox = try #require(await repository.cards(scope: .active).first)
    let beforeCount = try await repository.pendingOutboxCount()
    let faulting = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await faulting.moveCardEnsuringInbox(inbox.id, to: .archived, replacementInbox: nil, now: .now)
    }
    #expect(try await repository.cards(scope: .all).count == 1)
    #expect(try await repository.pendingOutboxCount() == beforeCount)
    try await faulting.moveCardEnsuringInbox(inbox.id, to: .archived, replacementInbox: nil, now: .now)
    let all = try await repository.cards(scope: .all)
    #expect(all.count == 2)
    #expect(all.filter(\.isInbox).count == 1)
    #expect(all.first(where: { $0.id == inbox.id })?.status == .archived)
    #expect(try await repository.pendingOutboxCount() == beforeCount + 2)
}

@Test func movingInboxAmongMultipleCandidatesRequiresChosenReplacement() async throws {
    let repository = try await InMemoryPetalRepository.bootstrapped()
    let inbox = try #require(await repository.cards(scope: .active).first(where: \.isInbox))
    let a = try await repository.createCard(title: "A", now: .now)
    let b = try await repository.createCard(title: "B", now: .now)
    let beforeCount = try await repository.pendingOutboxCount()
    await #expect(throws: RepositoryError.replacementInboxRequired) {
        try await repository.moveCardEnsuringInbox(inbox.id, to: .trashed, replacementInbox: nil, now: .now)
    }
    #expect(try await repository.pendingOutboxCount() == beforeCount)
    try await repository.moveCardEnsuringInbox(inbox.id, to: .trashed, replacementInbox: b.id, now: .now)
    #expect(try await repository.card(id: b.id)?.isInbox == true)
    #expect(try await repository.card(id: a.id)?.isInbox == false)
    #expect(try await repository.card(id: inbox.id)?.status == .trashed)
}
