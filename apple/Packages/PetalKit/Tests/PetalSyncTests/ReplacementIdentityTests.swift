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

@Test(arguments: ["archived", "trashed", "unflagged", "malformed", "redacted"])
func replacementStagesUnavailableInitialInboxWithoutDiscardingUnrelatedRecords(kind: String) async throws {
    let (generation, expected, marker) = identityFixture()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.applyInbound([marker], token: Data([1]), now: identityNow)
    var invalid = expected
    if kind == "archived" { invalid.status = .archived; invalid.archivedAt = identityNow; invalid.isInbox = false }
    if kind == "trashed" { invalid.status = .trashed; invalid.deletedAt = identityNow; invalid.isInbox = false }
    if kind == "unflagged" { invalid.isInbox = false }
    if kind == "malformed" { invalid.deletedAt = identityNow }
    let payload: ReplicatedRecord.Payload = kind == "redacted" ? .tombstone(SyncTombstone(id: UUID(), entity: .card,
        entityID: expected.id.rawValue, deletedAt: identityNow, deviceID: "sender", revision: 2)) : .card(invalid)
    let incoming = ReplicatedRecord(payload: payload, generation: generation,
        replacementInboxID: expected.id.rawValue)
    var other = expected
    other = Card(id: CardID(rawValue: UUID()), title: "Unrelated content", status: .active, themeID: .cream,
        isInbox: false, createdAt: identityNow, modifiedAt: identityNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "sender")
    try await repository.applyInbound([incoming, ReplicatedRecord(payload: .card(other), generation: generation)], token: Data([2]), now: identityNow)
    #expect(try await repository.card(id: other.id)?.title == "Unrelated content")
    #expect(try await repository.syncSnapshot().token == Data([2]))
    if kind == "malformed" {
        #expect(try await repository.card(id: expected.id) == nil)
        #expect(try await repository.conflicts().count == 1)
    } else if kind != "redacted" {
        #expect(try await repository.card(id: expected.id)?.status == invalid.status)
    }
    try await repository.transferSnapshot().validate()
    #expect(try await repository.syncSnapshot().replacementDeliveryStatus == .awaitingValidInitialInbox)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).count == 1)
    let current = UserStateChange(resetGeneration: generation.id, inboxCardID: other.id, replacementMode: false,
        revision: 2, modifiedAt: identityNow.addingTimeInterval(1), deviceID: "sender")
    try await repository.applyInbound([ReplicatedRecord(payload: .userState(current), generation: generation)], token: Data([3]), now: identityNow)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).map(\.id) == [other.id])
    #expect(try await repository.syncSnapshot().replacementDeliveryStatus == .complete)
}

@Test func legacyReplacementNeedsMarkerInsteadOfGuessingFromContent() async throws {
    let (generation, expected, _) = identityFixture()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Old data", now: identityNow)
    let content = ReplicatedRecord(payload: .card(expected), generation: generation)
    try await repository.applyInbound([content], token: Data([1]), now: identityNow)
    #expect(try await repository.syncSnapshot().replacementDeliveryStatus == .awaitingDeclaration)
    let marker = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation.id,
        inboxCardID: expected.id)), generation: generation)
    try await repository.applyInbound([marker], token: Data([2]), now: identityNow)
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
