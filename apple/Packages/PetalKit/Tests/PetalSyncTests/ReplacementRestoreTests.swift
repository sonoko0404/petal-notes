import Foundation
import CloudKit
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private let restoreNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test(arguments: ["title", "line", "status"], [false, true])
func replacementPlaceholderPreservesCommittedEditsAcrossRestart(edit: String, acknowledged: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let restored = try await sender.createCard(title: "Restored", now: restoreNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: restoreNow)
    let records = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    let receiver = try open()
    try await receiver.applyInbound(records.filter { if case .userState = $0.payload { true } else { false } }, token: nil, now: restoreNow)
    let placeholder = try #require(await receiver.cards(scope: .active).first)
    switch edit {
    case "title": _ = try await receiver.updateCardTitle(placeholder.id, title: "Local title", now: restoreNow)
    case "line": _ = try await receiver.addLine(NewLineDraft(cardID: placeholder.id, kind: .todo, text: "Local line"), now: restoreNow)
    default: try await receiver.moveCardEnsuringInbox(placeholder.id, to: .archived, replacementInbox: nil, now: restoreNow)
    }
    // Acknowledged edits must still count as mutations after restart.
    if acknowledged { try await receiver.acknowledgeSync(receiver.pendingOutbox()) }
    let reopened = try open()
    try await reopened.applyInbound(records, token: nil, now: restoreNow)
    let preserved = try #require(await reopened.card(id: placeholder.id))
    #expect(!preserved.isInbox)
    if edit == "title" { #expect(preserved.title == "Local title") }
    if edit == "status" { #expect(preserved.status == .archived) }
    if edit == "line" { #expect(try await reopened.lines(cardID: placeholder.id).first?.text == "Local line") }
    #expect(try await reopened.pendingOutbox().contains { $0.entityID == placeholder.id.rawValue && $0.operation == .upsert })
    #expect(try await reopened.cards(scope: .active).filter(\.isInbox).map(\.id) == [restored.id])
}

@Test func replacementPlaceholderRollbackRetainsEditsOutboxAndReplayIdentity() async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await sender.createCard(title: "Real Inbox", now: restoreNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: restoreNow)
    let records = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    let container = try ModelContainerFactory.makeInMemory()
    let receiver = SwiftDataPetalRepository(container: container)
    try await receiver.applyInbound(records.filter { if case .userState = $0.payload { true } else { false } }, token: nil, now: restoreNow)
    let placeholder = try #require(await receiver.cards(scope: .active).first)
    _ = try await receiver.updateCardTitle(placeholder.id, title: "Keep on rollback", now: restoreNow)
    let before = try await receiver.transferSnapshot()
    let outbox = try await receiver.pendingOutbox()
    let failing = SwiftDataPetalRepository(container: container, faultInjector: .failOnceBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) { try await failing.applyInbound(records, token: Data([1]), now: restoreNow) }
    #expect(try await receiver.transferSnapshot() == before)
    #expect(try await receiver.pendingOutbox() == outbox)
    try await failing.applyInbound(records, token: Data([1]), now: restoreNow)
    #expect(try await failing.card(id: placeholder.id)?.title == "Keep on rollback")
    #expect(try await failing.cards(scope: .active).filter(\.isInbox).count == 1)
}

@Test func replacementGenerationSurvivesOldTombstonesAcrossDevicesAndPartialReplay() async throws {
    let a = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let b = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await a.createCard(title: "Restored same ID", now: restoreNow)
    let line = try await a.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Keep me"), now: restoreNow)
    let backup = try await a.transferSnapshot()
    let initial = try await CloudRecordMapper.outbound(a.syncSnapshot()).map(\.record)
    try await b.applyInbound(initial, token: nil, now: restoreNow)
    _ = try await b.createCard(title: "Other old data", now: restoreNow)
    let tombstone = ReplicatedRecord(payload: .tombstone(SyncTombstone(id: UUID(), entity: .card,
        entityID: card.id.rawValue, deletedAt: restoreNow, deviceID: "remote", revision: 2)), generation: .initial)
    try await a.applyInbound([tombstone], token: nil, now: restoreNow)
    try await b.applyInbound([tombstone], token: nil, now: restoreNow)
    try await a.replaceUserData(backup, now: restoreNow.addingTimeInterval(1))
    let restoredGeneration = try await a.syncSnapshot().generation
    #expect(restoredGeneration > .initial)
    try await a.applyInbound([tombstone] + initial, token: nil, now: restoreNow.addingTimeInterval(2))
    #expect(try await a.card(id: card.id)?.title == "Restored same ID")
    let outbound = try await CloudRecordMapper.outbound(a.syncSnapshot())
    let marker = try #require(outbound.first { if case .userState = $0.record.payload { true } else { false } })
    try await b.applyInbound([try CloudRecordMapper.decode(CloudRecordMapper.encode(marker.record))], token: nil, now: restoreNow)
    #expect(try await b.cards(scope: .all).allSatisfy { $0.title != "Other old data" })
    try await b.applyInbound([tombstone] + initial, token: nil, now: restoreNow)
    let content = try outbound.filter { $0.id != marker.id }.map { try CloudRecordMapper.decode(CloudRecordMapper.encode($0.record)) }
    try await b.applyInbound(content.reversed(), token: nil, now: restoreNow)
    try await b.applyInbound([tombstone] + initial + content, token: nil, now: restoreNow)
    #expect(try await b.cards(scope: .all).map(\.id) == [card.id])
    #expect(try await b.card(id: card.id)?.title == "Restored same ID")
    #expect(try await b.lines(cardID: card.id).map(\.id) == [line.id])
    #expect(try await b.syncSnapshot().tombstones.isEmpty)
    try await a.replaceUserData(backup, now: restoreNow.addingTimeInterval(-100))
    #expect(try await a.syncSnapshot().generation > restoredGeneration)
    #expect(try await a.cards(scope: .active).filter(\.isInbox).count == 1)
}

private actor RestoreTransport: CloudTransport {
    enum Mode { case rejectMarker, failContent, accept }
    let mode: Mode
    var batches: [[ReplicatedRecord]] = []
    init(_ mode: Mode) { self.mode = mode }
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult { CloudFetchResult(records: [], token: nil) }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        batches.append(changes.map(\.record))
        let hasContent = changes.contains { if case .userState = $0.record.payload { false } else { true } }
        if mode == .failContent && hasContent { throw CloudTransportError.unavailable }
        return CloudSendResult(acceptedIDs: mode == .rejectMarker ? [] : Set(changes.map(\.id)))
    }
}

@Test func replacementMarkerMustBeAcknowledgedBeforeContentAndRestartRetriesPendingRows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open()
    let card = try await repository.createCard(title: "Survives transport failure", now: restoreNow)
    let backup = try await repository.transferSnapshot()
    try await repository.replaceUserData(backup, now: restoreNow)
    let rejecting = RestoreTransport(.rejectMarker)
    await CloudSyncCoordinator(repository: repository, transport: rejecting, now: { restoreNow }).sync(reason: .userRequested)
    let first = try #require(await rejecting.batches.first)
    #expect(first.count == 1)
    #expect(first.allSatisfy { if case .userState = $0.payload { true } else { false } })
    #expect(try await repository.pendingOutbox().contains { $0.entity == .userState })
    let failed = RestoreTransport(.failContent)
    let reopened = try open()
    await CloudSyncCoordinator(repository: reopened, transport: failed, now: { restoreNow }).sync(reason: .userRequested)
    #expect(await failed.batches.count == 2)
    #expect(try await reopened.pendingOutbox().allSatisfy { $0.entity == .card || $0.entity == .line })
    #expect(try await reopened.card(id: card.id)?.title == card.title)
    let succeeded = RestoreTransport(.accept)
    let restarted = try open()
    await CloudSyncCoordinator(repository: restarted, transport: succeeded, now: { restoreNow }).sync(reason: .userRequested)
    #expect(try await restarted.pendingOutboxCount() == 0)
    #expect(try await restarted.card(id: card.id)?.title == card.title)
}

@Test func legacyGenerationDecodesWithoutReplacementFlag() throws {
    let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000000","modifiedAt":-978307200,"deviceID":""}"#.utf8)
    let decoded = try JSONDecoder().decode(ResetGeneration.self, from: legacy)
    #expect(decoded == .initial)
    #expect(!decoded.isReplacement)
    let record = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: decoded.id,
        inboxCardID: CardID(rawValue: decoded.id))), generation: decoded)
    let ck = try CloudRecordMapper.encode(record)
    ck["resetIsReplacement"] = nil
    #expect(try CloudRecordMapper.decode(ck) == record)
}

@Test func replacementPagesPreserveDeclaredInboxEvenWhenOtherCardsArriveFirst() async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let receiver = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    func card(_ id: String, inbox: Bool) -> Card {
        Card(id: CardID(rawValue: UUID(uuidString: id)!), title: inbox ? "Chosen Inbox" : "Other", status: .active,
            themeID: .cream, isInbox: inbox, createdAt: restoreNow, modifiedAt: restoreNow,
            archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "")
    }
    let inbox = card("ffffffff-ffff-ffff-ffff-ffffffffffff", inbox: true)
    let other = card("11111111-1111-1111-1111-111111111111", inbox: false)
    try await sender.replaceUserData(TransferSnapshot(cards: [inbox, other], lines: []), now: restoreNow)
    let records = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    for id in [other.id, inbox.id] {
        let page = records.filter { if case .card(let card) = $0.payload { return card.id == id }; return false }
        try await receiver.applyInbound(page, token: nil, now: restoreNow)
    }
    #expect(try await receiver.cards(scope: .active).filter(\.isInbox).map(\.id) == [inbox.id])
    #expect(try await receiver.cards(scope: .all).count == 2)
}

@Test func cloudDecoderRejectsUnsupportedReplacementMode() throws {
    let record = ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: .init(),
        inboxCardID: CardID(rawValue: .init()))), generation: .initial)
    let ck = try CloudRecordMapper.encode(record)
    ck["resetIsReplacement"] = 2 as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(ck) }
}

@Test func normalResetExplicitlyClearsPriorCloudReplacementFlag() throws {
    let oldGeneration = ResetGeneration(id: UUID(), modifiedAt: restoreNow, deviceID: "device", isReplacement: true)
    let newGeneration = ResetGeneration(id: UUID(), modifiedAt: restoreNow.addingTimeInterval(1), deviceID: "device")
    func marker(_ generation: ResetGeneration) -> ReplicatedRecord {
        ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation.id,
            inboxCardID: CardID(rawValue: generation.id))), generation: generation)
    }
    let server = try CloudRecordMapper.encode(marker(oldGeneration))
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([server])
    let update = try buffer.prepare(marker(newGeneration))
    // CKRecord updates apply changed keys; an omitted optional field does not
    // clear the previous server value. Exercise the real prepared change set.
    for key in update.changedKeys() { server[key] = update[key] }
    #expect(try CloudRecordMapper.decode(server).generation == newGeneration)
}
