import CloudKit
import Foundation
import Testing
import SwiftData
import PetalCore
@testable import PetalPersistence
@testable import PetalSync

private let identityNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func replacementInboxEnvelopeClearsOldValueAndRejectsMalformedIdentity() throws {
    let (_, _, marker) = identityFixture()
    let server = try CloudRecordMapper.encode(marker)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([server])
    let ordinary = ReplicatedRecord(payload: marker.payload, generation: .initial)
    let update = try buffer.prepare(ordinary)
    for key in update.changedKeys() { server[key] = update[key] }
    #expect(try CloudRecordMapper.decode(server).replacementInboxID == nil)
    server["replacementInboxID"] = "not-a-uuid" as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(server) }
    server["replacementInboxID"] = 1 as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(server) }
}

@Test @MainActor func completedLegacyReplacementDoesNotRequireReplayingOldMarker() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    var card = try await repository.createCard(title: "Existing", now: identityNow)
    try await repository.replaceUserData(repository.transferSnapshot(), now: identityNow)
    // Simulate the previously shipped completed metadata without this optional field.
    let context = ModelContext(store.container)
    let row = try #require(context.fetch(FetchDescriptor<PetalSchemaV2.StoredSyncMetadata>()).first)
    var metadata = try JSONDecoder().decode(LocalSyncMetadata.self, from: #require(row.payload))
    metadata.replacementExpectedInboxID = nil
    row.payload = try JSONEncoder().encode(metadata); try context.save()
    card = try #require(await repository.card(id: card.id))
    card.title = "Remote edit"; card.modifiedAt = identityNow.addingTimeInterval(10)
    try await repository.applyInbound([ReplicatedRecord(payload: .card(card), generation: metadata.generation)], token: Data([1]), now: identityNow)
    #expect(try await repository.card(id: card.id)?.title == "Remote edit")
}

private func identityFixture() -> (ResetGeneration, Card, ReplicatedRecord) {
    let generation = ResetGeneration(id: UUID(), modifiedAt: identityNow, deviceID: "sender", isReplacement: true)
    let card = Card(id: CardID(rawValue: UUID()), title: "Expected", status: .active, themeID: .cream,
        isInbox: true, createdAt: identityNow, modifiedAt: identityNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "sender")
    let marker = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation.id, inboxCardID: card.id)),
        generation: generation, replacementInboxID: card.id.rawValue)
    return (generation, card, marker)
}

@Test(arguments: ["archived", "trashed", "unflagged", "mismatch", "redacted"])
func replacementExpectedInboxRejectsInvalidArrivalWithoutCheckpointMutation(kind: String) async throws {
    let (generation, expected, marker) = identityFixture()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.applyInbound([marker], token: Data([1]), now: identityNow)
    let before = try await repository.transferSnapshot()
    let outbox = try await repository.pendingOutbox()
    var invalid = expected
    if kind == "archived" { invalid.status = .archived; invalid.archivedAt = identityNow }
    if kind == "trashed" { invalid.status = .trashed; invalid.deletedAt = identityNow }
    if kind == "unflagged" { invalid.isInbox = false }
    let payload: ReplicatedRecord.Payload = kind == "redacted" ? .tombstone(SyncTombstone(id: UUID(), entity: .card,
        entityID: expected.id.rawValue, deletedAt: identityNow, deviceID: "sender", revision: 2)) : .card(invalid)
    let incoming = ReplicatedRecord(payload: payload, generation: generation,
        replacementInboxID: kind == "mismatch" ? UUID() : expected.id.rawValue)
    await #expect(throws: RepositoryError.replacementInboxRequired) {
        try await repository.applyInbound([incoming], token: Data([2]), now: identityNow)
    }
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == outbox)
    #expect(try await repository.syncSnapshot().token == Data([1]))
    try await repository.applyInbound([ReplicatedRecord(payload: .card(expected), generation: generation,
        replacementInboxID: expected.id.rawValue)], token: Data([3]), now: identityNow)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).map(\.id) == [expected.id])
    #expect(try await repository.cards(scope: .all).count == 1)
}

@Test func legacyReplacementNeedsMarkerInsteadOfGuessingFromContent() async throws {
    let (generation, expected, _) = identityFixture()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Old data", now: identityNow)
    let before = try await repository.transferSnapshot()
    let content = ReplicatedRecord(payload: .card(expected), generation: generation)
    await #expect(throws: RepositoryError.replacementInboxRequired) {
        try await repository.applyInbound([content], token: Data([1]), now: identityNow)
    }
    #expect(try await repository.transferSnapshot() == before)
    let marker = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation.id,
        inboxCardID: expected.id)), generation: generation)
    try await repository.applyInbound([marker, content], token: Data([2]), now: identityNow)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).map(\.id) == [expected.id])
    #expect(try await repository.cards(scope: .all).count == 1)
}

@Test(arguments: [false, true], [false, true])
func replacementInboxWaitsForDeclaredIdentityAcrossAcknowledgedEchoAndRestart(contentFirst: Bool, legacy: Bool) async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    // The placeholder sorts before the declared Inbox, making the old failure deterministic.
    let inbox = Card(id: CardID(rawValue: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
        title: "Declared Inbox", status: .active, themeID: .cream, isInbox: true, createdAt: identityNow,
        modifiedAt: identityNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "sender")
    try await sender.replaceUserData(TransferSnapshot(cards: [inbox], lines: []), now: identityNow)
    let outbound = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map { change in
        let native = try CloudRecordMapper.encode(change.record)
        if legacy { native["replacementInboxID"] = nil }
        return try CloudRecordMapper.decode(native)
    }
    let marker = outbound.filter { if case .userState = $0.payload { true } else { false } }
    let content = outbound.filter { if case .card = $0.payload { true } else { false } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open(fault: RepositoryFaultInjector = .none) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }), faultInjector: fault)
    }
    let receiver = try open()
    try await receiver.applyInbound(marker, token: nil, now: identityNow)
    let placeholder = try #require(await receiver.cards(scope: .active).first)
    _ = try await receiver.updateCardTitle(placeholder.id, title: "Local edit", now: identityNow.addingTimeInterval(1))
    let pending = try await CloudRecordMapper.outbound(receiver.syncSnapshot())
    let echo = try pending.map { try CloudRecordMapper.decode(CloudRecordMapper.encode($0.record)) }
    try await receiver.acknowledgeSync(pending.flatMap(\.journal))
    let reopened = try open()
    for page in contentFirst ? [content, echo, echo] : [echo, echo, content] {
        if page == content {
            let before = try await reopened.transferSnapshot()
            let journal = try await reopened.pendingOutbox()
            let failed = try open(fault: .failOnceBeforeSave)
            await #expect(throws: RepositoryError.injectedFailure) {
                try await failed.applyInbound(page, token: Data([2]), now: identityNow.addingTimeInterval(2))
            }
            #expect(try await reopened.transferSnapshot() == before)
            #expect(try await reopened.pendingOutbox() == journal)
        }
        try await reopened.applyInbound(page, token: Data([1]), now: identityNow.addingTimeInterval(2))
    }
    #expect(try await reopened.card(id: placeholder.id)?.title == "Local edit")
    #expect(try await reopened.card(id: placeholder.id)?.isInbox == false)
    #expect(try await reopened.cards(scope: .active).filter(\.isInbox).map(\.id) == [inbox.id])
    #expect(try await reopened.pendingOutbox().contains { $0.entityID == placeholder.id.rawValue })
}
