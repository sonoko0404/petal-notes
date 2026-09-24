import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private actor AccountLookupGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<CKAccountStatus, Never>?
    func status() async -> CKAccountStatus {
        if entered { return .noAccount }
        entered = true; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { held = $0 }
    }
    func waitForLookup() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { held?.resume(returning: .available); held = nil }
}

@Test func cancellationDuringAccountLookupNeverConstructsEngine() async throws {
    let gate = AccountLookupGate()
    let driver = CKEngineDriver(containerIdentifier: "fixture-never-connect", accountStatus: { await gate.status() },
        makeEngine: { _, _, _ in Issue.record("Cancelled lookup constructed engine"); throw CloudTransportError.unavailable })
    let fetch = Task { try await driver.fetch(checkpoint: nil) }
    await gate.waitForLookup()
    await driver.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await fetch.value }
}

@Test func disableReenableDuringNativeAccountLookupKeepsOldPassFenced() async throws {
    let gate = AccountLookupGate()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Durable pending edit", now: .now)
    let driver = CKEngineDriver(containerIdentifier: "fixture-never-connect", accountStatus: { await gate.status() },
        makeEngine: { _, _, _ in Issue.record("Obsolete account lookup created engine"); throw CloudTransportError.unavailable })
    let coordinator = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: driver))
    let running = await coordinator.request(reason: .launch)
    await gate.waitForLookup()
    try await coordinator.setEnabled(false)
    let enabling = Task { try await coordinator.setEnabled(true) }
    while try !(await repository.syncSnapshot().enabled) { await Task.yield() }
    await gate.release()
    await running.value; try await enabling.value
    #expect(await coordinator.state == .failed(.authenticationRequired))
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.syncSnapshot().token == nil)
}

private func recordWithServerTag(_ value: ReplicatedRecord) throws -> CKRecord {
    let record = try CloudRecordMapper.encode(value)
    let archive = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archive)
    archive.encode("server-tag-before-delete", forKey: "fixtureTag")
    archive.finishEncoding()
    var plist = try #require(PropertyListSerialization.propertyList(from: archive.encodedData, format: nil) as? [String: Any])
    var top = try #require(plist["$top"] as? [String: Any])
    // CKRecord's encoded system-field key, inspected locally. Test fixture only.
    top["ETag"] = top.removeValue(forKey: "fixtureTag"); plist["$top"] = top
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    let decoder = try NSKeyedUnarchiver(forReadingFrom: data); decoder.requiresSecureCoding = true
    defer { decoder.finishDecoding() }
    let tagged = try #require(CKRecord(coder: decoder))
    for key in record.allKeys() { tagged[key] = record[key] }
    return tagged
}

private actor MissingItemEngineFixture: SyncEngineDriving {
    var buffer = try! EngineEventBuffer(checkpoint: nil)
    var calls: [String] = []
    var preparedTags: [String?] = []
    private var firstSend = true
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        calls.append("fetch"); buffer = try EngineEventBuffer(checkpoint: checkpoint)
        return try buffer.fetchResult()
    }
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        calls.append("send"); buffer.beginSend()
        for value in records {
            let record = try buffer.prepare(value)
            preparedTags.append(record.recordChangeTag)
            if firstSend { buffer.didFailToSave(record, error: CKError(.unknownItem)) }
            else { buffer.didSave([record]) }
        }
        firstSend = false
        return try buffer.sendResult()
    }
    func cancel() async {}
}

@Test func missingServerRecordRestartsWithFetchBeforeAllowedCreateAndAcknowledgement() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await repository.createCard(title: "Permitted restoration", now: instant)
    let change = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first)
    var saved = try EngineEventBuffer(checkpoint: nil)
    try saved.receive([recordWithServerTag(change.record)])
    try await repository.applyInbound([], token: saved.checkpoint(), now: instant)
    let engine = MissingItemEngineFixture()
    let first = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { instant },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    await first.sync(reason: .foreground)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.syncSnapshot().retryAt == instant.addingTimeInterval(2))
    let restarted = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { instant.addingTimeInterval(10) })
    await restarted.sync(reason: .foreground)
    #expect(await engine.calls == ["fetch", "send", "fetch", "send"])
    #expect(await engine.preparedTags == ["server-tag-before-delete", nil])
    #expect(try await repository.pendingOutboxCount() == 0)
    #expect(await restarted.state == .synced(instant.addingTimeInterval(10)))
}

@Test func physicalDeletionClearsRealChangeTagInStagedCheckpointAcrossRestart() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Restorable", now: .now)
    let change = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first)
    let tagged = try recordWithServerTag(change.record)
    #expect(tagged.recordChangeTag == "server-tag-before-delete")
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([tagged])
    let committed = try buffer.checkpoint()
    #expect(try EngineEventBuffer(checkpoint: committed).prepare(change.record).recordChangeTag == "server-tag-before-delete")
    buffer.didDelete([tagged.recordID])
    let resumed = try EngineEventBuffer(checkpoint: buffer.checkpoint())
    #expect(try resumed.prepare(change.record).recordChangeTag == nil)
    // Discarding the staged checkpoint must leave the committed archive intact.
    #expect(try EngineEventBuffer(checkpoint: committed).prepare(change.record).recordChangeTag == "server-tag-before-delete")
}

@Test func unknownItemStagesTagRemovalWithoutAcknowledgingAndRequiresFreshPolicyPass() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Newer restoration", now: .now)
    let change = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first)
    let tagged = try recordWithServerTag(change.record)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([tagged]); buffer.beginSend()
    buffer.didFailToSave(tagged, error: CKError(.unknownItem))
    let result = try buffer.sendResult()
    #expect(result.requiresRefetch)
    #expect(result.savedRecordIDs.isEmpty)
    try await repository.acknowledgeSync([], token: result.checkpoint)
    #expect(try await repository.pendingOutboxCount() == 1)
    let resumed = try EngineEventBuffer(checkpoint: await repository.syncSnapshot().token)
    #expect(try resumed.prepare(change.record).recordChangeTag == nil)
    // The next fetch may forbid this restoration; no create is attempted before merge.
    let fence = SyncTombstone(id: UUID(), entity: .card, entityID: card.id.rawValue, deletedAt: .now, deviceID: "remote", revision: 2)
    try await repository.applyInbound([ReplicatedRecord(payload: .tombstone(fence), generation: .initial)], token: result.checkpoint, now: .now)
    #expect(try !CloudRecordMapper.outbound(await repository.syncSnapshot()).contains { CloudRecordMapper.identity($0.record).id == card.id.rawValue })
}

@Test func atomicBatchFailureDoesNotDiscardMissingRecordRecoveryCheckpoint() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Missing", now: .now)
    _ = try await repository.createCard(title: "Sibling", now: .now)
    let changes = try CloudRecordMapper.outbound(await repository.syncSnapshot())
    var buffer = try EngineEventBuffer(checkpoint: nil)
    let records = try changes.map { try recordWithServerTag($0.record) }
    try buffer.receive(records); buffer.beginSend()
    buffer.didFailToSave(records[1], error: CKError(.batchRequestFailed))
    buffer.didFailToSave(records[0], error: CKError(.unknownItem))
    let result = try buffer.sendResult()
    #expect(result.requiresRefetch && result.savedRecordIDs.isEmpty)
    let resumed = try EngineEventBuffer(checkpoint: result.checkpoint)
    #expect(try resumed.prepare(changes[0].record).recordChangeTag == nil)
    #expect(try resumed.prepare(changes[1].record).recordChangeTag == "server-tag-before-delete")
}

@Test func engineEventsRejectFailedFetchCheckpointAndUnappliedSendInbound() async throws {
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.failure = .networkUnavailable
    #expect(throws: CloudTransportError.networkUnavailable) { try buffer.fetchResult() }
    buffer.beginSend()
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Arrived during send", now: .now)
    let change = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first)
    let record = try CloudRecordMapper.encode(change.record)
    buffer.didSave([record])
    #expect(try buffer.sendResult().savedRecordIDs == Set([CloudRecordMapper.identity(change.record).id]))
    try buffer.receive([record])
    #expect(throws: CloudTransportError.conflict) { try buffer.sendResult() }
}

@Test func checkpointContainsOnlyEngineStateAndSystemFieldsAndRestoresInboundBoundary() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "DO-NOT-PERSIST-IN-TOKEN", now: .now)
    let change = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first)
    let native = try CloudRecordMapper.encode(change.record)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([native])
    buffer.engineState = Data([8, 9])
    let token = try buffer.checkpoint()
    #expect(!String(decoding: token, as: UTF8.self).contains("DO-NOT-PERSIST-IN-TOKEN"))
    let resumed = try EngineEventBuffer(checkpoint: token)
    #expect(resumed.engineState == Data([8, 9]))
    #expect(resumed.inbound.isEmpty)
    #expect(buffer.inbound == [change.record])
    #expect(try CloudRecordMapper.decode(resumed.prepare(change.record)) == change.record)
    #expect(throws: CloudTransportError.invalidRecord) { try EngineEventBuffer(checkpoint: Data([255])) }
}

private actor EngineFixture: SyncEngineDriving {
    var restored: [Data?] = []
    var accepted: Set<UUID> = []
    func accept(_ id: UUID) { accepted.insert(id) }
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        restored.append(checkpoint)
        return CloudFetchResult(records: [], token: Data([10]))
    }
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        EngineSendResult(savedRecordIDs: accepted, checkpoint: Data([11]))
    }
    func cancel() async {}
}

@Test func engineCheckpointRestoresAndOnlyConfirmedRecordsAcknowledge() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let a = try await repository.createCard(title: "Confirmed", now: .now)
    _ = try await repository.createCard(title: "Unsent", now: .now)
    let engine = EngineFixture()
    await engine.accept(a.id.rawValue)
    let transport = CKSyncTransport(engine: engine)
    let fetch = try await transport.fetchChanges(after: Data([9]))
    #expect(fetch.token == Data([10]))
    #expect(await engine.restored == [Data([9])])
    let changes = try CloudRecordMapper.outbound(try await repository.syncSnapshot())
    let result = try await transport.send(changes)
    #expect(result.acceptedIDs.count == 1)
    #expect(result.acceptedIDs == Set(changes.filter { CloudRecordMapper.identity($0.record).id == a.id.rawValue }.map(\.id)))
    #expect(result.token == Data([11]))
}

@Test func cloudErrorsMapToSafeValuesAndRetainRetryAfter() {
    #expect(CKSyncTransport.failure(CKError(.networkUnavailable)) == .networkUnavailable)
    #expect(CKSyncTransport.failure(CKError(.notAuthenticated)) == .authenticationRequired)
    #expect(CKSyncTransport.failure(CKError(.quotaExceeded)) == .quotaExceeded)
    #expect(CKSyncTransport.failure(CKError(.accountTemporarilyUnavailable)) == .accountUnavailable)
    #expect(CKSyncTransport.failure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60])) == .retryAfter(60))
    #expect(CKSyncTransport.failure(NSError(domain: "private-content", code: 42)) == .unavailable)
}
