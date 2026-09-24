import Foundation
import Testing
import PetalCore
import SwiftData
@testable import PetalPersistence

private let syncNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func resettingAgainRetainsUnsentDeletionIntentForAlreadyRemovedRecords() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let old = try await repository.createCard(title: "Old", now: syncNow)
    try await repository.deleteAllData(resetGeneration: UUID(), now: syncNow.addingTimeInterval(1))
    let first = try #require(await repository.syncSnapshot().tombstones.first { $0.entityID == old.id.rawValue })
    try await repository.deleteAllData(resetGeneration: UUID(), now: syncNow.addingTimeInterval(2))
    #expect(try await repository.pendingOutbox().contains { $0.operation == .delete && $0.entityID == old.id.rawValue })
    #expect(try await repository.syncSnapshot().tombstones.first { $0.entityID == old.id.rawValue }?.id == first.id)
}

@Test func metadataOnlyDifferencesDoNotCreateUserConflictArtifacts() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Same", now: syncNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Same"), now: syncNow)
    var remote = line; remote.modifiedAt = syncNow.addingTimeInterval(1); remote.revision = 10; remote.deviceID = "remote"
    try await repository.applyInbound([ReplicatedRecord(payload: .line(remote), generation: .initial)], token: nil, now: syncNow)
    #expect(try await repository.conflicts().isEmpty)
    #expect(try await repository.lines(cardID: card.id).first?.revision == 10)
}

@Test func independentInboxesConvergeToExactlyOneAndParentArrivesBeforeLine() async throws {
    let a = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let b = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let first = try await a.createCard(title: "A", now: syncNow)
    let second = try await b.createCard(title: "B", now: syncNow)
    let line = try await b.addLine(NewLineDraft(cardID: second.id, kind: .text, text: "Remote"), now: syncNow)
    try await a.applyInbound([ReplicatedRecord(payload: .line(line), generation: .initial), ReplicatedRecord(payload: .card(second), generation: .initial)], token: nil, now: syncNow)
    try await b.applyInbound([ReplicatedRecord(payload: .card(first), generation: .initial)], token: nil, now: syncNow)
    let left = try await a.cards(scope: .active).filter(\.isInbox)
    let right = try await b.cards(scope: .active).filter(\.isInbox)
    #expect(left.count == 1 && right.count == 1)
    #expect(left.first?.id == right.first?.id)
    #expect(try await a.lines(cardID: second.id) == [line])
}

@Test func expiredTombstoneDoesNotDeleteLaterEditAndOlderGenerationGetsDeletionIntent() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Later", now: syncNow.addingTimeInterval(2))
    let tombstone = SyncTombstone(id: UUID(), entity: .card, entityID: card.id.rawValue, deletedAt: syncNow, deviceID: "remote", revision: 1)
    try await repository.applyInbound([ReplicatedRecord(payload: .tombstone(tombstone), generation: .initial)], token: nil, now: syncNow.addingTimeInterval(2_592_000))
    #expect(try await repository.card(id: card.id)?.title == "Later")
    try await repository.deleteAllData(resetGeneration: UUID(), now: syncNow.addingTimeInterval(3))
    var unseen = card
    unseen = Card(id: CardID(rawValue: UUID()), title: "Unseen old generation", status: .active, themeID: .cream, isInbox: false,
        createdAt: syncNow, modifiedAt: syncNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "remote")
    try await repository.applyInbound([ReplicatedRecord(payload: .card(unseen), generation: .initial)], token: nil, now: syncNow.addingTimeInterval(4))
    #expect(try await repository.card(id: unseen.id) == nil)
    #expect(try await repository.pendingOutbox().contains { $0.entityID == unseen.id.rawValue && $0.operation == .delete })
}

@Test func versionOneStoreMigratesWithRecoverySnapshotAndKeepsLocalEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Library/Application Support/Petal")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = CardID(rawValue: UUID())
    do {
        let schema = Schema(versionedSchema: PetalSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: directory.appendingPathComponent("Petal.sqlite"), cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.insert(try PetalSchemaV1.StoredCard(Card(id: id, title: "Legacy", status: .active, themeID: .cream,
            isInbox: true, createdAt: syncNow, modifiedAt: syncNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "legacy")))
        try context.save()
    }
    try Data("1".utf8).write(to: directory.appendingPathComponent("Petal.schema-version"))
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    #expect(try await repository.card(id: id)?.title == "Legacy")
    #expect(try String(contentsOf: directory.appendingPathComponent("Petal.schema-version"), encoding: .utf8) == "2")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Petal.pre-v2-recovery.json").path))
    try await repository.setSyncEnabled(false)
    #expect(try await repository.syncSnapshot().enabled == false)
    try await repository.deleteAllData(resetGeneration: UUID(), now: syncNow)
    try await repository.finishResetCleanup()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Petal.pre-v2-recovery.json").path))
}

@Test func acknowledgementAndEngineCheckpointRollbackTogether() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    _ = try await repository.createCard(title: "Pending", now: syncNow)
    try await repository.applyInbound([], token: Data([1]), now: syncNow)
    let sent = try await repository.pendingOutbox()
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.acknowledgeSync(sent, token: Data([2]))
    }
    #expect(try await repository.syncSnapshot().token == Data([1]))
    #expect(try await repository.pendingOutboxCount() == 1)
    try await repository.acknowledgeSync(sent, token: Data([2]))
    #expect(try await repository.syncSnapshot().token == Data([2]))
    #expect(try await repository.pendingOutboxCount() == 0)
}

@Test func localRetentionPurgeProducesDurableContentFreeTombstones() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: syncNow)
    let card = try await repository.createCard(title: "Expired", now: syncNow)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: syncNow)
    try await repository.purgeExpiredTrash(now: syncNow.addingTimeInterval(2_592_000))
    #expect(try await repository.syncSnapshot().tombstones.map(\.entityID) == [card.id.rawValue])
}

@Test func resetCreatesDurableTombstonesAndNewGenerationPurgesOtherDevice() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    let old = try await repository.createCard(title: "Old", now: syncNow)
    let line = try await repository.addLine(NewLineDraft(cardID: old.id, kind: .todo, text: "Old"), now: syncNow)
    let generationID = UUID()
    try await repository.deleteAllData(resetGeneration: generationID, now: syncNow.addingTimeInterval(5))
    let snapshot = try await repository.syncSnapshot()
    #expect(snapshot.generation.id == generationID)
    #expect(Set(snapshot.tombstones.map(\.entityID)) == Set([old.id.rawValue, line.id.rawValue]))
    #expect(snapshot.changes.filter { $0.operation == .delete }.count == 2)
    #expect(snapshot.changes.allSatisfy { !String(decoding: $0.payload, as: UTF8.self).contains("Old") })
    let other = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let offline = try await other.createCard(title: "Offline", now: syncNow)
    let reset = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generationID, inboxCardID: CardID(rawValue: generationID))), generation: snapshot.generation)
    try await other.applyInbound([ReplicatedRecord(payload: .card(old), generation: .initial), reset], token: Data([4]), now: syncNow.addingTimeInterval(6))
    let cards = try await other.cards(scope: .all)
    #expect(cards.count == 1 && cards.first?.isInbox == true)
    #expect(cards.first?.id.rawValue == generationID)
    #expect(try await other.card(id: offline.id) == nil)
    #expect(try await other.resetGeneration() == generationID)
    #expect(try await other.syncSnapshot().token == Data([4]))
}

@Test func tombstoneDeletesCardChildrenAndFencesOfflineResurrection() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: syncNow)
    let card = try await repository.createCard(title: "Deleted", now: syncNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Old"), now: syncNow)
    let tombstone = SyncTombstone(id: UUID(), entity: .card, entityID: card.id.rawValue,
        deletedAt: syncNow.addingTimeInterval(1), deviceID: "remote", revision: 2)
    try await repository.applyInbound([ReplicatedRecord(payload: .tombstone(tombstone), generation: .initial)], token: Data([1]), now: syncNow)
    var newer = card; newer.modifiedAt = syncNow.addingTimeInterval(2); newer.title = "Offline"
    try await repository.applyInbound([
        ReplicatedRecord(payload: .card(newer), generation: .initial),
        ReplicatedRecord(payload: .line(line), generation: .initial)
    ], token: Data([2]), now: syncNow.addingTimeInterval(3))
    #expect(try await repository.card(id: card.id) == nil)
    #expect(try await repository.lines(cardID: card.id).isEmpty)
    #expect(try await repository.pendingOutbox().allSatisfy { $0.entityID != card.id.rawValue && $0.entityID != line.id.rawValue })
    #expect(try await repository.syncSnapshot().tombstones == [tombstone])
    try await repository.applyInbound([ReplicatedRecord(payload: .card(card), generation: .initial)], token: Data([3]), now: syncNow.addingTimeInterval(2_592_002))
    #expect(try await repository.card(id: card.id) == nil)
    try await repository.applyInbound([ReplicatedRecord(payload: .card(newer), generation: .initial)], token: Data([4]), now: syncNow.addingTimeInterval(2_592_002))
    #expect(try await repository.card(id: card.id)?.title == "Offline")
}

@Test(arguments: [false, true]) func sameLineConflictUsesDateThenDeviceAndPreservesLoserOnce(remoteWins: Bool) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Shared", now: syncNow)
    let local = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Local draft"), now: syncNow)
    var remote = local
    remote.text = "Remote draft"
    remote.deviceID = remoteWins ? "zzzz" : "0000"
    let batch = [ReplicatedRecord(payload: .line(remote), generation: .initial)]
    try await repository.applyInbound(batch, token: Data([1]), now: syncNow)
    #expect(try await repository.lines(cardID: card.id).first?.text == (remoteWins ? "Remote draft" : "Local draft"))
    let conflicts = try await repository.takeUnpresentedConflicts(now: syncNow)
    #expect(conflicts.count == 1)
    #expect(try JSONDecoder().decode(CardLine.self, from: #require(conflicts.first).losingPayload).text == (remoteWins ? "Local draft" : "Remote draft"))
    #expect(try await repository.takeUnpresentedConflicts(now: syncNow).isEmpty)
    try await repository.applyInbound(batch, token: Data([2]), now: syncNow)
    #expect(try await repository.conflicts().count == 1)
    #expect(try await repository.pendingOutbox().filter { $0.entity == .line }.count == (remoteWins ? 0 : 1))
    try await repository.purgeExpiredConflicts(now: syncNow.addingTimeInterval(2_592_000))
    #expect(try await repository.conflicts().isEmpty)
}

@Test func inboundBatchAndTokenCommitTogetherAndDistinctLinesMerge() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    let card = try await repository.createCard(title: "Shared", now: syncNow)
    let local = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Local"), now: syncNow)
    var remote = local
    remote = CardLine(id: LineID(rawValue: UUID()), cardID: card.id, kind: .text, text: "Remote",
        sortIndex: 1, isCompleted: false, completedAt: nil, lastDailyCompletionKey: nil, dailyStreak: 0,
        reminder: nil, createdAt: syncNow, modifiedAt: syncNow, deletedAt: nil, revision: 1, deviceID: "remote")
    let batch = [ReplicatedRecord(payload: .line(remote), generation: .initial)]
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.applyInbound(batch, token: Data([9]), now: syncNow)
    }
    #expect(try await repository.lines(cardID: card.id) == [local])
    #expect(try await repository.syncSnapshot().token == nil)
    try await repository.applyInbound(batch, token: Data([9]), now: syncNow)
    #expect(try await repository.lines(cardID: card.id).map(\.text) == ["Local", "Remote"])
    #expect(try await repository.syncSnapshot().token == Data([9]))
    #expect(try await repository.pendingOutboxCount() == 2)
}

@Test func syncAcknowledgesOnlyExactSentChangesAndKeepsNewerEdits() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    let card = try await repository.createCard(title: "Before", now: syncNow)
    let sent = try await repository.syncSnapshot()
    _ = try await repository.updateCardTitle(card.id, title: "After", now: syncNow.addingTimeInterval(1))
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.acknowledgeSync(sent.changes)
    }
    #expect(try await repository.pendingOutboxCount() == 2)
    try await repository.acknowledgeSync(sent.changes)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.card(id: card.id)?.title == "After")
    try await repository.setSyncEnabled(false)
    let reopened = SwiftDataPetalRepository(container: store)
    #expect(try await reopened.syncSnapshot().enabled == false)
    #expect(try await reopened.syncSnapshot().changes.count == 1)
}
