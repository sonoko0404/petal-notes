import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private let safetyNow = Date(timeIntervalSince1970: 1_800_000_000)
private func safetyCard(_ id: UUID = UUID()) -> Card {
    Card(id: CardID(rawValue: id), title: "Private", status: .active, themeID: .cream,
         isInbox: true, createdAt: safetyNow, modifiedAt: safetyNow,
         archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "test")
}
private func safetyLine(_ card: Card, id: UUID = UUID(), index: Int64 = 0) -> CardLine {
    CardLine(id: LineID(rawValue: id), cardID: card.id, kind: .todo, text: "Private line", sortIndex: index,
             isCompleted: false, completedAt: nil, lastDailyCompletionKey: nil, dailyStreak: 0, reminder: nil,
             createdAt: safetyNow, modifiedAt: safetyNow, deletedAt: nil, revision: 1, deviceID: "test")
}

@Test(arguments: ["crossEntity", "reservedCard", "reservedLine", "maxOrder", "minOrder"])
func finalRestoreRejectsUnsafeIdentityAndOrderingWithoutMutation(kind: String) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Keep existing", now: safetyNow)
    let before = try await repository.transferSnapshot()
    let journal = try await repository.pendingOutbox()
    let card = safetyCard(kind == "reservedCard" ? CloudRecordMapper.userStateID : UUID())
    let line = safetyLine(card, id: kind == "crossEntity" ? card.id.rawValue : kind == "reservedLine" ? CloudRecordMapper.userStateID : UUID(),
                          index: kind == "maxOrder" ? .max : kind == "minOrder" ? .min : 0)
    await #expect(throws: (any Error).self) {
        try await repository.replaceUserData(TransferSnapshot(cards: [card], lines: [line]), now: safetyNow)
    }
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == journal)
}

@Test func finalNativeBatchRejectsDuplicateRecordIDsRecoverably() throws {
    let card = safetyCard()
    let record = ReplicatedRecord(payload: .card(card), generation: .initial)
    let buffer = try EngineEventBuffer(checkpoint: nil)
    #expect(throws: CloudTransportError.invalidRecord) { try buffer.prepareSend([record, record]) }
    #expect(throws: CloudTransportError.invalidRecord) {
        try buffer.prepareSend([record, ReplicatedRecord(payload: .line(safetyLine(card, id: card.id.rawValue)), generation: .initial)])
    }
}

@Test(arguments: [false, true])
func finalInboundCollisionAndExtremeOrderNeverPoisonCanonicalData(reverse: Bool) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Keep", now: safetyNow)
    let unsafe = [safetyLine(card, id: card.id.rawValue), safetyLine(card, index: .max)]
    let batch = unsafe.map { ReplicatedRecord(payload: .line($0), generation: .initial) }
    try await repository.applyInbound(reverse ? batch.reversed() : batch, token: Data([1]), now: safetyNow)
    #expect(try await repository.lines(cardID: card.id).isEmpty)
    #expect(try await repository.conflicts().count == 2)
    #expect(try await repository.card(id: card.id) == card)
}

@Test func finalImportRejectsCrossEntityCollisionWithExistingData() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let existing = try await repository.createCard(title: "Keep", now: safetyNow)
    let card = Card(id: CardID(rawValue: UUID()), title: "Imported", status: .active, themeID: .cream,
        isInbox: false, createdAt: safetyNow, modifiedAt: safetyNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "import")
    let before = try await repository.transferSnapshot()
    await #expect(throws: TransferRepositoryError.invalidSnapshot) {
        try await repository.importCards([ImportedCard(card: card, lines: [safetyLine(card, id: existing.id.rawValue)],
            fingerprint: "unique", sourceNoteID: UUID())], now: safetyNow) { _ in }
    }
    #expect(try await repository.transferSnapshot() == before)
}

@Test func finalInboundRejectsReservedGenerationBeforeResettingLocalData() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let existing = try await repository.createCard(title: "Keep", now: safetyNow)
    let bad = ReplicatedRecord(payload: .card(safetyCard()), generation: ResetGeneration(
        id: CloudRecordMapper.userStateID, modifiedAt: safetyNow, deviceID: "malformed"))
    try await repository.applyInbound([bad], token: Data([1]), now: safetyNow)
    #expect(try await repository.cards(scope: .all) == [existing])
    #expect(try await repository.syncSnapshot().generation == .initial)
    #expect(try await repository.conflicts().count == 1)
}

@Test func finalInboundCrossEntityTombstonesAreQuarantinedBeforeTheyCanPoisonReset() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Keep", now: safetyNow)
    let id = UUID()
    let records = [SyncTombstone.Entity.card, .line].map {
        ReplicatedRecord(payload: .tombstone(SyncTombstone(id: UUID(), entity: $0, entityID: id,
            deletedAt: safetyNow, deviceID: "untrusted", revision: 1)), generation: .initial)
    }
    try await repository.applyInbound(records, token: Data([1]), now: safetyNow)
    #expect(try await repository.syncSnapshot().tombstones.isEmpty)
    #expect(try await repository.conflicts().count == 2)
}

@Test func finalExtremeInboundRevisionFailsEditRecoverablyWithoutPoisoningLaterReset() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    var card = safetyCard(); card.revision = Int64.max - 1
    try await repository.applyInbound([ReplicatedRecord(payload: .card(card), generation: .initial)], token: nil, now: safetyNow)
    await #expect(throws: RepositoryError.invalidOrder) {
        try await repository.updateCardTitle(card.id, title: "Retain this draft", now: safetyNow)
    }
    #expect(try await repository.card(id: card.id)?.revision == Int64.max - 1)
}

@Test(arguments: ["reservedParent", "unrepresentableDate", "unrepresentableReminder", "unrepresentableSnooze"])
func finalMalformedFutureGenerationCannotDiscardTheCurrentDataset(kind: String) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let existing = try await repository.createCard(title: "Keep current", now: safetyNow)
    var line = safetyLine(safetyCard(kind == "reservedParent" ? CloudRecordMapper.userStateID : UUID()))
    if kind == "unrepresentableDate" { line.completedAt = Date(timeIntervalSince1970: 1e100) }
    if kind == "unrepresentableReminder" {
        line.reminder = Reminder(rule: .oneTime(Date(timeIntervalSince1970: 1e100)), isEnabled: true)
    }
    if kind == "unrepresentableSnooze" {
        line.reminder = Reminder(rule: .daily(localMinute: 600, timeZoneIdentifier: "UTC"), isEnabled: true,
            snoozedUntil: Date(timeIntervalSince1970: 1e100))
    }
    let next = ResetGeneration(id: UUID(), modifiedAt: safetyNow.addingTimeInterval(1), deviceID: "malformed")
    try await repository.applyInbound([ReplicatedRecord(payload: .line(line), generation: next)], token: nil, now: safetyNow)
    #expect(try await repository.cards(scope: .all) == [existing])
    #expect(try await repository.syncSnapshot().generation == .initial)
    #expect(try await repository.conflicts().count == 1)
}

/// Incremental fetches deliberately omit records delivered before a restore.
private actor ErasureService: CloudTransport {
    var records: [UUID: ReplicatedRecord] = [:]
    var fullFetches = 0
    var failSend = false
    var incremental: [ReplicatedRecord] = []
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        if token == nil { fullFetches += 1 }
        defer { incremental = [] }
        return CloudFetchResult(records: token == nil ? Array(records.values) : incremental, token: Data([42]))
    }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        if failSend { throw CloudTransportError.unavailable }
        for change in changes { records[CloudRecordMapper.identity(change.record).id] = change.record }
        return CloudSendResult(acceptedIDs: Set(changes.map(\.id)), token: Data([42]))
    }
    func setFailure(_ value: Bool) { failSend = value }
    func payload(_ id: UUID) -> ReplicatedRecord.Payload? { records[id]?.payload }
    func inject(_ record: ReplicatedRecord) {
        records[CloudRecordMapper.identity(record).id] = record; incremental.append(record)
    }
}

@Test func finalIncomingResetScansForgottenRecordsAndRedactsStaleDevicesAfterAcknowledgement() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let service = ErasureService()
    let old = try await repository.createCard(title: "Old", now: safetyNow)
    let stale = ReplicatedRecord(payload: .card(old), generation: .initial)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .launch)
    try await repository.replaceUserData(TransferSnapshot(cards: [safetyCard()], lines: []), now: safetyNow.addingTimeInterval(1))
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    let remote = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await remote.deleteAllData(resetGeneration: UUID(), now: safetyNow.addingTimeInterval(2))
    let reset = try await CloudRecordMapper.outbound(remote.syncSnapshot()).map(\.record)
    try await repository.applyInbound(reset, token: Data([99]), now: safetyNow.addingTimeInterval(2))
    #expect(try await repository.syncSnapshot().erasureScanGeneration != nil)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .push)
    guard case .tombstone = await service.payload(old.id.rawValue) else { Issue.record("Incoming reset omitted full erasure"); return }
    #expect(try await repository.syncSnapshot().erasureScanGeneration == nil)
    // A stale device can replay old content even after our first redaction was acknowledged.
    await service.inject(stale)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .push)
    guard case .tombstone = await service.payload(old.id.rawValue) else { Issue.record("Stale replay retained payload"); return }
    #expect(try await repository.card(id: old.id) == nil)
}

@Test func finalRestoreDuringPendingDeleteAllKeepsErasureObligationAndNewContent() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let service = ErasureService()
    let old = try await repository.createCard(title: "Erase old", now: safetyNow)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .launch)
    try await repository.deleteAllData(resetGeneration: UUID(), now: safetyNow.addingTimeInterval(1))
    let restored = safetyCard()
    try await repository.replaceUserData(TransferSnapshot(cards: [restored], lines: []), now: safetyNow.addingTimeInterval(2))
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    guard case .tombstone = await service.payload(old.id.rawValue),
          case .card(let copy) = await service.payload(restored.id.rawValue) else {
        Issue.record("Restore lost erasure or replacement payload"); return
    }
    #expect(copy.title == restored.title)
}

@Test(arguments: [false, true])
func finalRestoreAfterCompletedScanAndFailedSendPreservesErasureAcrossRestart(incoming: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open(), service = ErasureService()
    let old = try await repository.createCard(title: "A before first restore", now: safetyNow)
    let line = try await repository.addLine(NewLineDraft(cardID: old.id, kind: .todo, text: "A private row"), now: safetyNow)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .launch)
    try await repository.replaceUserData(TransferSnapshot(cards: [safetyCard()], lines: []), now: safetyNow.addingTimeInterval(1))
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    try await repository.deleteAllData(resetGeneration: UUID(), now: safetyNow.addingTimeInterval(2))
    await service.setFailure(true)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    // Fetch completed and persisted its checkpoint, but cloud content has not
    // been erased. Replacement must not discard the remaining obligation.
    #expect(try await repository.syncSnapshot().erasureScanGeneration == nil)
    #expect(try await repository.pendingOutbox().contains { $0.entityID == old.id.rawValue && $0.operation == .delete })
    let restored = safetyCard()
    let backup = TransferSnapshot(cards: [restored], lines: [safetyLine(restored)])
    if incoming {
        let origin = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await origin.replaceUserData(backup, now: safetyNow.addingTimeInterval(3))
        try await open().applyInbound(CloudRecordMapper.outbound(origin.syncSnapshot()).map(\.record),
            token: Data([99]), now: safetyNow.addingTimeInterval(3))
    } else {
        try await open().replaceUserData(backup, now: safetyNow.addingTimeInterval(3))
    }
    let reopened = try open()
    let pending = try await reopened.syncSnapshot()
    #expect(pending.erasureScanGeneration != nil || pending.changes.contains {
        $0.entityID == old.id.rawValue && $0.operation == .delete
    })
    await service.setFailure(false)
    await CloudSyncCoordinator(repository: reopened, transport: service).sync(reason: .retry)
    guard case .tombstone = await service.payload(old.id.rawValue),
          case .tombstone = await service.payload(line.id.rawValue) else {
        Issue.record("Completed scan plus failed send plus restore forgot cloud payload A"); return
    }
    #expect(try await reopened.card(id: restored.id)?.title == restored.title)
    #expect(try await reopened.lines(cardID: restored.id).count == 1)
    #expect(try await reopened.syncSnapshot().erasureScanGeneration == nil)
}

@Test func finalStaleScanCompletionCannotClearReplacementRescanObligation() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.deleteAllData(resetGeneration: UUID(), now: safetyNow)
    let scanning = try #require(await repository.syncSnapshot().erasureScanGeneration)
    let old = safetyCard()
    try await repository.applyInbound([ReplicatedRecord(payload: .card(old), generation: .initial)],
        token: Data([42]), now: safetyNow)
    try await repository.replaceUserData(TransferSnapshot(cards: [safetyCard()], lines: []),
        now: safetyNow.addingTimeInterval(1))
    // Models a replacement committed between an in-flight scan's inbound
    // transaction and its subsequent finish callback.
    try await repository.finishErasureScan(generation: scanning, token: Data([42]), expectedEpoch: nil)
    #expect(try await repository.syncSnapshot().erasureScanGeneration != nil)
}

@Test func finalErasureCannotFenceANewerReplacementDeliveredWithStaleHistory() async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let receiver = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let restored = safetyCard()
    let backup = TransferSnapshot(cards: [restored], lines: [safetyLine(restored)])
    let stale = ReplicatedRecord(payload: .card(restored), generation: .initial)
    try await sender.deleteAllData(resetGeneration: UUID(), now: safetyNow)
    try await receiver.applyInbound(CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record), token: nil, now: safetyNow)
    try await sender.replaceUserData(backup, now: safetyNow.addingTimeInterval(1))
    let replacement = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    try await receiver.applyInbound([stale] + replacement, token: nil, now: safetyNow.addingTimeInterval(1))
    #expect(try await receiver.card(id: restored.id)?.title == "Private")
    #expect(try await receiver.lines(cardID: restored.id).count == 1)
    #expect(try await receiver.syncSnapshot().tombstones.allSatisfy { $0.entityID != restored.id.rawValue })
}

@Test func finalDeleteAllRediscoversForgottenGenerationsAcrossDisabledSyncRestartAndRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open(), service = ErasureService()
    let old = try await repository.createCard(title: "Forgotten after restore", now: safetyNow)
    let line = try await repository.addLine(NewLineDraft(cardID: old.id, kind: .todo, text: "Forgotten line"), now: safetyNow)
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    try await repository.replaceUserData(TransferSnapshot(cards: [safetyCard()], lines: []), now: safetyNow.addingTimeInterval(1))
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .userRequested)
    try await repository.setSyncEnabled(false)
    try await repository.deleteAllData(resetGeneration: UUID(), now: safetyNow.addingTimeInterval(2))
    await CloudSyncCoordinator(repository: repository, transport: service).sync(reason: .localMutation)
    #expect(await service.fullFetches == 1)
    let reopened = try open()
    try await reopened.setSyncEnabled(true)
    await service.setFailure(true)
    await CloudSyncCoordinator(repository: reopened, transport: service).sync(reason: .userRequested)
    #expect(try await reopened.pendingOutbox().contains { $0.entityID == old.id.rawValue && $0.operation == .delete })
    await service.setFailure(false)
    await CloudSyncCoordinator(repository: try open(), transport: service).sync(reason: .retry)
    guard case .tombstone = await service.payload(old.id.rawValue),
          case .tombstone = await service.payload(line.id.rawValue) else {
        Issue.record("Delete All left user payload from a forgotten generation in the service"); return
    }
    #expect(await service.fullFetches >= 2)
    #expect(try await reopened.cards(scope: .all).count == 1)
    #expect(try await reopened.lines(cardID: old.id).isEmpty)
}

@Test(arguments: [false, true])
func finalLateReplacementSupersedesOldErasureWithoutPublishingANewerDeletion(acknowledged: Bool) async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let receiver = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = safetyCard()
    let child = safetyLine(card)
    try await sender.deleteAllData(resetGeneration: UUID(), now: safetyNow)
    let erasure = try await sender.syncSnapshot().generation
    try await receiver.applyInbound(CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record), token: nil, now: safetyNow)
    try await sender.replaceUserData(TransferSnapshot(cards: [card], lines: [child]), now: safetyNow.addingTimeInterval(1))
    let replacement = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    let marker = replacement.filter { if case .userState = $0.payload { true } else { false } }
    let stale = [ReplicatedRecord(payload: .card(card), generation: .initial),
                 ReplicatedRecord(payload: .line(child), generation: .initial)]
    try await receiver.applyInbound(marker + stale, token: nil, now: safetyNow.addingTimeInterval(2))
    let cleanup = try await CloudRecordMapper.outbound(receiver.syncSnapshot()).filter {
        if case .tombstone = $0.record.payload { true } else { false }
    }
    #expect(cleanup.count == 2)
    #expect(cleanup.allSatisfy { $0.record.generation == erasure })
    // An erasure helper must not delete the origin's already restored content.
    try await sender.applyInbound(cleanup.map(\.record), token: nil, now: safetyNow.addingTimeInterval(3))
    #expect(try await sender.card(id: card.id) != nil)
    #expect(try await sender.lines(cardID: card.id).count == 1)
    if acknowledged { try await receiver.acknowledgeSync(cleanup.flatMap(\.journal)) }
    // Child-before-parent delivery must buffer the new child despite the old
    // parent's erasure fence, then resolve it when the restored card arrives.
    try await receiver.applyInbound(replacement.filter { if case .line = $0.payload { true } else { false } },
        token: nil, now: safetyNow.addingTimeInterval(4))
    try await receiver.applyInbound(replacement.filter { if case .line = $0.payload { false } else { true } },
        token: nil, now: safetyNow.addingTimeInterval(5))
    #expect(try await receiver.card(id: card.id)?.title == card.title)
    #expect(try await receiver.lines(cardID: card.id).count == 1)
    #expect(try await receiver.syncSnapshot().tombstones.allSatisfy {
        $0.entityID != card.id.rawValue && $0.entityID != child.id.rawValue
    })
    #expect(try await receiver.pendingOutbox().allSatisfy {
        $0.entityID != card.id.rawValue && $0.entityID != child.id.rawValue
    })
}
