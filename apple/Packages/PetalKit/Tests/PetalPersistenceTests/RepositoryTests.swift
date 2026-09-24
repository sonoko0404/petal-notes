import Foundation
import Testing
import PetalCore
import PetalTestSupport
@testable import PetalPersistence

private let instant = Date(timeIntervalSince1970: 1_800_000_000)

@Test func outboxKeepsCommitOrderWhenWallClockMovesBackwards() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: instant)
    let card = try await repository.createCard(title: "Card", now: instant)
    try await repository.moveCard(card.id, to: .archived, replacementInbox: nil, now: instant.addingTimeInterval(-10))
    let changes = try await repository.pendingOutbox().filter { $0.entityID == card.id.rawValue }
    #expect(try changes.map { try JSONDecoder().decode(Card.self, from: $0.payload).status } == [.active, .archived])
}

@Test func diskFailureRemainsRolledBackAfterReopeningStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let failing = SwiftDataPetalRepository(
            container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }),
            faultInjector: .failBeforeSave
        )
        await #expect(throws: RepositoryError.injectedFailure) {
            try await failing.createCard(title: "Must not persist", now: instant)
        }
    }
    let reopened = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    #expect(try await reopened.cards(scope: .all).isEmpty)
    #expect(try await reopened.pendingOutboxCount() == 0)
}

@Test func sharedFactoryRejectsUnavailableAppGroup() {
    #expect(throws: RepositoryError.appGroupUnavailable) {
        try ModelContainerFactory.makeShared(appGroupID: "missing.group", containerURL: { _ in nil })
    }
}

@Test func fixtureBuilderUsesRealRepositoryAndDeterministicClock() async throws {
    var clock = DeterministicClock(now: instant)
    clock.advance(by: 10)
    let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 3, now: clock.now)
    let lines = try await fixture.repository.lines(cardID: fixture.fixtureCardID)
    #expect(lines.count == 3)
    #expect(lines.map(\.text) == ["Todo 1", "Todo 2", "Todo 3"])
    #expect(lines.allSatisfy { $0.kind == .todo && $0.createdAt == instant.addingTimeInterval(10) })
    #expect(try await fixture.repository.cards(scope: .active).filter(\.isInbox).count == 1)
    try await fixture.repository.setCompleted(lineID: lines[0].id, completed: true, now: clock.now)
    #expect(try await fixture.repository.lines(cardID: fixture.fixtureCardID).first?.isCompleted == true)
}

@Test func expiryDoesNotRetainExpiredContentInPendingOutbox() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: instant)
    let card = try await repository.createCard(title: "Expired secret", now: instant)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Expired secret"), now: instant)
    let conflict = try await repository.captureConflict(cardID: card.id, lineID: line.id, losingPayload: Data("Expired secret".utf8), now: instant)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: instant)
    try await repository.purgeExpiredTrash(now: instant.addingTimeInterval(2_592_000))
    try await repository.purgeExpiredConflicts(now: instant.addingTimeInterval(2_592_000))
    let changes = try await repository.pendingOutbox().filter { [card.id.rawValue, line.id.rawValue, conflict.id].contains($0.entityID) }
    #expect(changes.count == 3)
    #expect(changes.allSatisfy { $0.operation == .delete && $0.payload.isEmpty })
}

@Test func deviceIdentityIsStableWithinStoreAndDifferentAcrossStores() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let first = SwiftDataPetalRepository(container: container)
    let reopened = SwiftDataPetalRepository(container: container)
    let other = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let a = try await first.createCard(title: "A", now: instant)
    let b = try await reopened.createCard(title: "B", now: instant)
    let c = try await other.createCard(title: "C", now: instant)
    #expect(a.deviceID == b.deviceID)
    #expect(a.deviceID != c.deviceID)
    let line = try await reopened.addLine(NewLineDraft(cardID: a.id, kind: .todo, text: "Task"), now: instant)
    #expect(line.deviceID == a.deviceID)
}

@Test func deleteAllDataReplacesContentsWithEmptyInboxAndResetGenerationAtomically() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    let card = try await repository.createCard(title: "Private", now: instant)
    _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Private"), now: instant)
    _ = try await repository.captureConflict(cardID: card.id, lineID: nil, losingPayload: Data("Private".utf8), now: instant)
    let generation = UUID()
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.deleteAllData(resetGeneration: generation, now: instant)
    }
    #expect(try await failing.card(id: card.id) == card)
    #expect(try await failing.conflicts().count == 1)
    #expect(try await failing.pendingOutboxCount() == 3)
    #expect(try await failing.resetGeneration() == nil)
    try await repository.deleteAllData(resetGeneration: generation, now: instant)
    let remaining = try await repository.cards(scope: .all)
    #expect(remaining.count == 1 && remaining.first?.isInbox == true)
    #expect(remaining.first?.id != card.id)
    #expect(try await repository.lines(cardID: card.id).isEmpty)
    #expect(try await repository.conflicts().isEmpty)
    #expect(try await repository.resetGeneration() == generation)
    #expect(try await repository.pendingOutboxCount() == 2)
    #expect(try await repository.pendingOutbox().contains { $0.entity == .userState })
}

@Test func conflictRetentionIsExactlyThirtyDaysAndTransactional() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    let card = try await repository.createCard(title: "Conflict", now: instant)
    let artifact = try await repository.captureConflict(cardID: card.id, lineID: nil, losingPayload: Data("draft".utf8), now: instant)
    #expect(artifact.expiresAt == instant.addingTimeInterval(2_592_000))
    #expect(!artifact.hasBeenPresented)
    try await repository.purgeExpiredConflicts(now: instant.addingTimeInterval(2_591_999))
    #expect(try await repository.conflicts() == [artifact])
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.purgeExpiredConflicts(now: instant.addingTimeInterval(2_592_000))
    }
    #expect(try await failing.conflicts() == [artifact])
    #expect(try await failing.pendingOutboxCount() == 2)
    try await repository.purgeExpiredConflicts(now: instant.addingTimeInterval(2_592_000))
    #expect(try await repository.conflicts().isEmpty)
}

@Test func trashPurgesAtExactlyThirtyDaysWithItsLinesAndDeletionOutbox() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    _ = try await repository.createCard(title: "Inbox", now: instant)
    let card = try await repository.createCard(title: "Trash", now: instant)
    _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Gone with card"), now: instant)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: instant)
    try await repository.purgeExpiredTrash(now: instant.addingTimeInterval(2_591_999))
    #expect(try await repository.card(id: card.id) != nil)
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.purgeExpiredTrash(now: instant.addingTimeInterval(2_592_000))
    }
    #expect(try await failing.card(id: card.id) != nil)
    #expect(try await failing.lines(cardID: card.id).count == 1)
    #expect(try await failing.pendingOutboxCount() == 4)
    try await repository.purgeExpiredTrash(now: instant.addingTimeInterval(2_592_000))
    #expect(try await repository.card(id: card.id) == nil)
    #expect(try await repository.lines(cardID: card.id).isEmpty)
    #expect(try await repository.pendingOutbox().filter { $0.operation == .delete }.count == 2)
}

@Test func futureSchemaRefusesOpenAndExistingWriterBeforeAnyWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    _ = try await repository.createCard(title: "Preserved", now: instant)
    let directory = root.appendingPathComponent("Library/Application Support/Petal")
    let marker = directory.appendingPathComponent("Petal.schema-version")
    try Data("2".utf8).write(to: marker, options: .atomic)
    let before = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    #expect(throws: RepositoryError.unsupportedSchema(2)) {
        try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root })
    }
    await #expect(throws: RepositoryError.unsupportedSchema(2)) {
        try await repository.createCard(title: "Must not write", now: instant)
    }
    let after = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    #expect(before == after)
    #expect(try await repository.pendingOutboxCount() == 1)
}

@Test func appAndWidgetShareOneStoreAndObserveEachOthersCommits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test.group", containerURL: { _ in root }))
    let widget = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test.group", containerURL: { _ in root }))
    async let a: Void = app.bootstrap(now: instant)
    async let b: Void = widget.bootstrap(now: instant)
    _ = try await (a, b)
    #expect(try await app.cards(scope: .active).filter(\.isInbox).count == 1)
    let card = try await app.createCard(title: "Shared", now: instant)
    #expect(try await widget.card(id: card.id)?.status == .active)
    try await app.moveCard(card.id, to: .archived, replacementInbox: nil, now: instant)
    #expect(try await widget.card(id: card.id)?.status == .archived)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Application Support/Petal/Petal.sqlite").path))
    #expect(try await widget.pendingOutboxCount() == 3)
}

@Test func searchMatchesTitlesAndMixedLinesAcrossAllScopes() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: instant)
    let card = try await repository.createCard(title: "Needle title", now: instant)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .text, text: "needle paragraph"), now: instant)
    _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "unrelated"), now: instant)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: instant)
    let matches = try await repository.search(" NEEDLE ")
    #expect(matches.count == 2)
    #expect(matches.contains(SearchResult(cardID: card.id, lineID: nil, title: "Needle title", snippet: "Needle title")))
    #expect(matches.contains(SearchResult(cardID: card.id, lineID: line.id, title: "Needle title", snippet: "needle paragraph")))
    #expect(try await repository.search("  ").isEmpty)
}

@Test func movingInboxRequiresActiveReplacementInSameTransaction() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    let inbox = try await repository.createCard(title: "Inbox", now: instant)
    let replacement = try await repository.createCard(title: "Replacement", now: instant)
    await #expect(throws: RepositoryError.replacementInboxRequired) {
        try await repository.moveCard(inbox.id, to: .trashed, replacementInbox: nil, now: instant)
    }
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.moveCard(inbox.id, to: .archived, replacementInbox: replacement.id, now: instant)
    }
    #expect(try await failing.cards(scope: .active).filter(\.isInbox).map(\.id) == [inbox.id])
    #expect(try await failing.pendingOutboxCount() == 2)
    try await repository.moveCard(inbox.id, to: .trashed, replacementInbox: replacement.id, now: instant)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).map(\.id) == [replacement.id])
    #expect(try await repository.card(id: inbox.id)?.deletedAt == instant)
    #expect(try await repository.cards(scope: .trashed).map(\.id) == [inbox.id])
    try await repository.moveCard(inbox.id, to: .active, replacementInbox: nil, now: instant)
    #expect(try await repository.card(id: inbox.id)?.deletedAt == nil)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).count == 1)
}

@Test func reorderRequiresExactPermutationAndRollsBackAllRows() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    let card = try await repository.createCard(title: "Work", now: instant)
    let a = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "A"), now: instant)
    let b = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .text, text: "B"), now: instant)
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.reorder(cardID: card.id, orderedLineIDs: [b.id, a.id], now: instant)
    }
    #expect(try await failing.lines(cardID: card.id) == [a, b])
    await #expect(throws: RepositoryError.invalidOrder) {
        try await repository.reorder(cardID: card.id, orderedLineIDs: [a.id, a.id], now: instant)
    }
    #expect(try await repository.pendingOutboxCount() == 3)
    try await repository.reorder(cardID: card.id, orderedLineIDs: [b.id, a.id], now: instant)
    #expect(try await repository.lines(cardID: card.id).map(\.id) == [b.id, a.id])
    #expect(try await repository.pendingOutboxCount() == 5)
}

@Test func completionPreservesManualOrderAndIsIdempotent() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Work", now: instant)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Task"), now: instant)
    try await repository.setCompleted(lineID: line.id, completed: true, now: instant)
    try await repository.setCompleted(lineID: line.id, completed: true, now: instant.addingTimeInterval(1))
    let completed = try #require(try await repository.lines(cardID: card.id).first)
    #expect(completed.isCompleted && completed.completedAt == instant && completed.sortIndex == 0)
    #expect(completed.revision == 2)
    #expect(try await repository.pendingOutboxCount() == 3)
    try await repository.setCompleted(lineID: line.id, completed: false, now: instant.addingTimeInterval(2))
    let undone = try #require(try await repository.lines(cardID: card.id).first)
    #expect(!undone.isCompleted && undone.completedAt == nil && undone.sortIndex == 0)
    await #expect(throws: RepositoryError.lineUnavailable) {
        try await repository.setCompleted(lineID: LineID(rawValue: UUID()), completed: true, now: instant)
    }
}

@Test func convertingTodoToTextClearsTodoStateAtomically() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container)
    let card = try await repository.createCard(title: "Work", now: instant)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Task", isCompleted: true,
        reminder: Reminder(rule: .oneTime(instant), isEnabled: true)), now: instant)
    let mutation = LineMutation(id: line.id, kind: .text, text: "Paragraph", reminder: nil)
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) { try await failing.updateLine(mutation, now: instant) }
    #expect(try await failing.lines(cardID: card.id) == [line])
    #expect(try await failing.pendingOutboxCount() == 2)
    let changed = try await repository.updateLine(mutation, now: instant.addingTimeInterval(1))
    #expect(changed.text == "Paragraph" && changed.kind == .text)
    #expect(!changed.isCompleted && changed.completedAt == nil && changed.reminder == nil)
    #expect(changed.revision == 2 && changed.modifiedAt == instant.addingTimeInterval(1))
    #expect(try await repository.lines(cardID: card.id) == [changed])
    #expect(try await repository.pendingOutboxCount() == 3)
}

@Test func addLinesPreservesOrderAndCommitsLinePayloads() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Work", now: instant)
    let a = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "First"), now: instant)
    let b = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .text, text: "Second"), now: instant)
    #expect(try await repository.lines(cardID: card.id) == [a, b])
    #expect(a.sortIndex == 0 && b.sortIndex == 1)
    #expect(!a.isCompleted && a.completedAt == nil && a.revision == 1)
    let changes = try await repository.pendingOutbox().filter { $0.entity == .line }
    #expect(changes.count == 2)
    #expect(try changes.map { try JSONDecoder().decode(CardLine.self, from: $0.payload) }.contains(b))
    await #expect(throws: RepositoryError.cardUnavailable) {
        try await repository.addLine(NewLineDraft(cardID: CardID(rawValue: UUID()), kind: .todo, text: "Orphan"), now: instant)
    }
    #expect(try await repository.pendingOutboxCount() == 3)
}

@Test func createCardCommitsDomainValueAndOutbox() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let first = try await repository.createCard(title: "First", now: instant)
    let second = try await repository.createCard(title: "Second", now: instant)
    #expect(first.isInbox)
    #expect(!second.isInbox)
    #expect(try await repository.card(id: second.id) == second)
    #expect(try await repository.card(id: CardID(rawValue: UUID())) == nil)
    let outbox = try await repository.pendingOutbox()
    #expect(outbox.count == 2)
    let change = try #require(outbox.first { $0.entityID == second.id.rawValue })
    #expect(change.entity == .card)
    #expect(change.operation == .upsert)
    #expect(try JSONDecoder().decode(Card.self, from: change.payload) == second)
}

@Test func bootstrapCreatesExactlyOneInbox() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: instant)
    try await repository.bootstrap(now: instant)
    let cards = try await repository.cards(scope: .active)
    #expect(cards.count == 1)
    #expect(cards.first?.isInbox == true)
    #expect(cards.first?.createdAt == instant)
}

@Test func entityAndOutboxRollbackTogether() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: container, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await repository.createCard(title: "Atomic", now: instant)
    }
    #expect(try await repository.cards(scope: .all).isEmpty)
    #expect(try await repository.pendingOutboxCount() == 0)
    let independentReader = SwiftDataPetalRepository(container: container)
    #expect(try await independentReader.cards(scope: .all).isEmpty)
    #expect(try await independentReader.pendingOutboxCount() == 0)
}
