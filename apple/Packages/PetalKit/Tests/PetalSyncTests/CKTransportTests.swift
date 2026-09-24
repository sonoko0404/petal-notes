import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private actor MixedRetryEngineFixture: SyncEngineDriving {
    let reverse: Bool
    let successive: Bool
    let network: Bool
    private(set) var calls: [String] = []
    private var shouldFail = true
    init(reverse: Bool, successive: Bool, network: Bool) {
        self.reverse = reverse; self.successive = successive; self.network = network
    }
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        calls.append("fetch")
        return CloudFetchResult(records: [], token: checkpoint)
    }
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        calls.append("send")
        var buffer = try EngineEventBuffer(checkpoint: nil)
        buffer.beginSend()
        let native = try records.map(CloudRecordMapper.encode)
        if shouldFail {
            shouldFail = false
            let record = try #require(native.first)
            var failures: [FailedRecordChange] = [
                .save(record, CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120])),
                .delete(record.recordID, CKError(network ? .networkUnavailable : .serverRecordChanged))
            ]
            if reverse { failures.reverse() }
            for event in successive ? failures.map({ [$0] }) : [failures] {
                buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: event)
            }
        } else { buffer.didSend(savedRecords: native, deletedRecordIDs: [], failures: []) }
        return try buffer.sendResult()
    }
    func cancel() async {}
}

private actor RetryDelayProbe {
    private(set) var delays: [TimeInterval] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(_ delay: TimeInterval) async throws {
        delays.append(delay); waiter?.resume(); waiter = nil
        try await Task.sleep(for: .seconds(3600))
    }
    func waitForSchedule() async { if delays.isEmpty { await withCheckedContinuation { waiter = $0 } } }
}

@Test(arguments: 0..<8)
func mixedRetryDeadlinesSurviveOrderingEventsRestartAndToggle(_ scenario: Int) async throws {
    let reverse = scenario & 1 != 0, successive = scenario & 2 != 0, network = scenario & 4 != 0
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "fixture", containerURL: { _ in root }))
    _ = try await repository.createCard(title: "Pending", now: instant)
    let engine = MixedRetryEngineFixture(reverse: reverse, successive: successive, network: network)
    let probe = RetryDelayProbe()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { instant },
        sleep: { try await probe.sleep($0) })
    await coordinator.sync(reason: .launch)
    await probe.waitForSchedule()
    #expect(await probe.delays == [120])
    #expect(try await repository.syncSnapshot().retryAt == instant.addingTimeInterval(120))
    #expect(await coordinator.state == (network ? .offline : .failed(.other("sync-unavailable"))))
    try await coordinator.setEnabled(false)
    try await coordinator.setEnabled(true)
    await coordinator.sync(reason: .localMutation)
    #expect(await engine.calls == ["fetch", "send"])
    try await coordinator.setEnabled(false)
    // Reopen the actual durable store: restarting cannot shorten the deadline.
    let reopened = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "fixture", containerURL: { _ in root }))
    let restartProbe = RetryDelayProbe()
    let beforeDeadline = instant.addingTimeInterval(119)
    let restarted = CloudSyncCoordinator(repository: reopened, transport: CKSyncTransport(engine: engine), now: { beforeDeadline },
        sleep: { try await restartProbe.sleep($0) })
    try await restarted.setEnabled(true)
    await restarted.sync(reason: .foreground)
    if try await reopened.syncSnapshot().retryAt != nil { await restartProbe.waitForSchedule() }
    #expect(await restartProbe.delays == [1])
    #expect(await engine.calls == ["fetch", "send"])
    #expect(try await reopened.pendingOutboxCount() == 1)
    try await restarted.setEnabled(false)
    let deadline = instant.addingTimeInterval(120)
    let ready = CloudSyncCoordinator(repository: reopened, transport: CKSyncTransport(engine: engine), now: { deadline })
    try await ready.setEnabled(true)
    #expect(await engine.calls == ["fetch", "send", "fetch", "send"])
    #expect(try await reopened.pendingOutboxCount() == 0)
}

@Test(arguments: [false, true])
func retryConstraintSurvivesNativeNormalizationAndLaterFetchErrors(reverse: Bool) throws {
    let errors = [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 45]),
        CKError(.networkUnavailable, userInfo: [CKErrorRetryAfterKey: 120]),
        CKError(.serverRecordChanged, userInfo: [CKErrorRetryAfterKey: 60])]
    var buffer = try EngineEventBuffer(checkpoint: nil)
    for error in reverse ? Array(errors.reversed()) : errors { buffer.recordFailure(error) }
    let expected = CloudTransportFailure(reason: .networkUnavailable, maxRetryAfter: 120)
    #expect(throws: expected) { try buffer.fetchResult() }
    #expect(throws: expected) { try buffer.sendResult() }
    let nested = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
        "network": errors[1], "throttle": errors[0], "conflict": errors[2]
    ]])
    #expect(CKSyncTransport.safeFailure(nested) as? CloudTransportFailure == expected)
}

@Test func atomicRecoveryAndAggregateThrowRetainRetryConstraints() throws {
    let record = CKRecord(recordType: "PTTombstone")
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.beginSend()
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: [
        .save(record, CKError(.batchRequestFailed, userInfo: [CKErrorRetryAfterKey: 180])),
        .delete(record.recordID, CKError(.unknownItem, userInfo: [CKErrorRetryAfterKey: 120]))
    ])
    let recovery = try buffer.sendResult()
    #expect(recovery.requiresRefetch)
    #expect(recovery.savedRecordIDs.isEmpty)
    #expect(recovery.maxRetryAfter == 180)
    // Aggregate operation errors are emitted after individual record events.
    buffer.recordRetryConstraint(CKError(.partialFailure, userInfo: [CKErrorRetryAfterKey: 240]))
    #expect(try buffer.sendResult().maxRetryAfter == 240)
}

private actor RecoveryRetryEngineFixture: SyncEngineDriving {
    private(set) var calls: [String] = []
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        calls.append("fetch")
        return CloudFetchResult(records: [], token: checkpoint)
    }
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        calls.append("send")
        return EngineSendResult(savedRecordIDs: [], checkpoint: Data("recovery".utf8), requiresRefetch: true, maxRetryAfter: 180)
    }
    func cancel() async {}
}

@Test func recoveryResultPersistsDeadlineWithoutAcknowledgingAbortedWork() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await repository.createCard(title: "Retained", now: instant)
    let engine = RecoveryRetryEngineFixture()
    let probe = RetryDelayProbe()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { instant },
        sleep: { try await probe.sleep($0) })
    await coordinator.sync(reason: .launch)
    await probe.waitForSchedule()
    #expect(await probe.delays == [180])
    #expect(try await repository.syncSnapshot().retryAt == instant.addingTimeInterval(180))
    #expect(try await repository.syncSnapshot().token == Data("recovery".utf8))
    #expect(try await repository.pendingOutboxCount() == 1)
    await coordinator.sync(reason: .push)
    #expect(await engine.calls == ["fetch", "send"])
    try await coordinator.setEnabled(false)
}

private actor MixedAtomicEngineFixture: SyncEngineDriving {
    private var buffer = try! EngineEventBuffer(checkpoint: nil)
    private var firstUnknownSave: Bool
    private let reverse: Bool
    private(set) var physicalDeleteAttempts: [String] = []
    init(firstUnknownSave: Bool, reverse: Bool) { self.firstUnknownSave = firstUnknownSave; self.reverse = reverse }
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        buffer = try EngineEventBuffer(checkpoint: checkpoint)
        return try buffer.fetchResult()
    }
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        buffer.beginSend()
        let plan = try buffer.prepareSend(records)
        physicalDeleteAttempts += plan.deletions.values.map(\.recordName)
        var failures: [FailedRecordChange] = []
        if !plan.deletions.isEmpty {
            if firstUnknownSave {
                let missingSave = try #require(plan.records.first { $0.recordType == "PTTombstone" })
                failures = plan.records.map { .save($0, CKError($0.recordID == missingSave.recordID ? .unknownItem : .batchRequestFailed)) }
                failures += plan.deletions.values.map { .delete($0, CKError(.batchRequestFailed)) }
                firstUnknownSave = false
            } else {
                // Deterministic external boundary: targets are already absent.
                // Retrying a physical delete would abort the same atomic batch.
                failures = plan.records.map { .save($0, CKError(.batchRequestFailed)) }
                failures += plan.deletions.values.map { .delete($0, CKError(.unknownItem)) }
            }
        }
        buffer.didSend(savedRecords: failures.isEmpty ? plan.records : [], deletedRecordIDs: [],
            failures: reverse ? Array(failures.reversed()) : failures)
        return try buffer.sendResult()
    }
    func cancel() async {}
}

@Test(arguments: [false, true], [false, true])
func mixedAtomicRecoveryMakesProgressAcrossRestartAndRepeatedReset(unknownSave: Bool, reverse: Bool) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let card = try await repository.createCard(title: "Removed", now: instant)
    try await repository.deleteAllData(resetGeneration: UUID(), now: instant.addingTimeInterval(1))
    let engine = MixedAtomicEngineFixture(firstUnknownSave: unknownSave, reverse: reverse)
    let attempts = unknownSave ? 3 : 2
    for attempt in 1...attempts {
        let timestamp = instant.addingTimeInterval(Double(attempt) * 10)
        let restarted = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { timestamp },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await restarted.sync(reason: .launch)
        if attempt < attempts { #expect(try await repository.pendingOutboxCount() == 3) }
        else {
            #expect(try await repository.pendingOutboxCount() == 0)
            #expect(await restarted.state == .synced(timestamp))
        }
    }
    let oldTargetAttempts = await engine.physicalDeleteAttempts.filter { $0 == card.id.rawValue.uuidString }.count
    #expect(oldTargetAttempts == (unknownSave ? 2 : 1))
    try await repository.deleteAllData(resetGeneration: UUID(), now: instant.addingTimeInterval(100))
    for attempt in 1...2 {
        let timestamp = instant.addingTimeInterval(100 + Double(attempt) * 10)
        let restarted = CloudSyncCoordinator(repository: repository, transport: CKSyncTransport(engine: engine), now: { timestamp },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await restarted.sync(reason: .launch)
        if attempt == 1 { #expect(try await repository.pendingOutboxCount() == 4) }
        else { #expect(try await repository.pendingOutboxCount() == 0) }
    }
    #expect(await engine.physicalDeleteAttempts.filter { $0 == card.id.rawValue.uuidString }.count == oldTargetAttempts)
    #expect(try await repository.cards(scope: .active).count == 1)
}

@Test(arguments: [false, true])
func mixedAtomicRetryAfterSelectionIsOrderIndependent(reverse: Bool) throws {
    let record = CKRecord(recordType: "PTCard")
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.beginSend()
    let failures: [FailedRecordChange] = [
        .save(record, CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 1e300])),
        .delete(record.recordID, CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 1e301]))
    ]
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: reverse ? Array(failures.reversed()) : failures)
    #expect(throws: CloudTransportError.retryAfter(1e301)) { try buffer.sendResult() }
}

@Test func absentPhysicalDeleteRestartsAsTombstoneOnlyUntilPublicationConfirmed() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let card = try await repository.createCard(title: "Delete", now: instant)
    try await repository.deleteAllData(resetGeneration: UUID(), now: instant.addingTimeInterval(1))
    let snapshot = try await repository.syncSnapshot()
    let change = try #require(CloudRecordMapper.outbound(snapshot).first { if case .tombstone = $0.record.payload { return true }; return false })
    let target = CKRecord.ID(recordName: card.id.rawValue.uuidString, zoneID: CloudRecordMapper.zoneID)
    let tombstone = try recordWithServerTag(change.record)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.beginSend()
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: [.delete(target, CKError(.unknownItem)),
        .save(tombstone, CKError(.batchRequestFailed))])
    let recovery = try buffer.sendResult()
    #expect(recovery.savedRecordIDs.isEmpty)
    try await repository.acknowledgeSync([], token: recovery.checkpoint)
    #expect(try await repository.pendingOutbox().contains { $0.id == change.id })
    var resumed = try EngineEventBuffer(checkpoint: await repository.syncSnapshot().token)
    let plan = try resumed.prepareSend([change.record])
    #expect(plan.deletions.isEmpty)
    #expect(plan.excludedDeletionIDs == [target])
    #expect(plan.records.map(\.recordID) == [tombstone.recordID])
    resumed.beginSend()
    resumed.didSend(savedRecords: plan.records, deletedRecordIDs: [], failures: [])
    let published = try resumed.sendResult()
    #expect(published.savedRecordIDs == Set([CloudRecordMapper.identity(change.record).id]))
    try await repository.acknowledgeSync(change.journal, token: published.checkpoint)
    #expect(try await !repository.pendingOutbox().contains { $0.id == change.id })
    // Repeat reset reuses the deletion fence; an already absent target must not
    // re-enter the atomic unknownItem loop after another process restart.
    try await repository.deleteAllData(resetGeneration: UUID(), now: instant.addingTimeInterval(2))
    let repeated = try #require(CloudRecordMapper.outbound(await repository.syncSnapshot()).first {
        if case .tombstone(let value) = $0.record.payload { return value.entityID == card.id.rawValue }; return false
    })
    var replay = try EngineEventBuffer(checkpoint: await repository.syncSnapshot().token)
    let replayPlan = try replay.prepareSend([repeated.record])
    #expect(replayPlan.deletions.isEmpty)
    #expect(replayPlan.excludedDeletionIDs == [target])
    replay.beginSend(); replay.didSend(savedRecords: replayPlan.records, deletedRecordIDs: [], failures: [])
    #expect(try replay.sendResult().savedRecordIDs == Set([CloudRecordMapper.identity(repeated.record).id]))
    try replay.receive([recordWithServerTag(ReplicatedRecord(payload: .card(card), generation: .initial))])
    #expect(try replay.prepareSend([repeated.record]).deletions[tombstone.recordID] == target)
}

@Test(arguments: [false, true])
func mixedAtomicRootFailureSelectionIsOrderIndependent(reverse: Bool) async throws {
    let record = CKRecord(recordType: "PTCard", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudRecordMapper.zoneID))
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.beginSend()
    let failures: [FailedRecordChange] = [.save(record, CKError(.quotaExceeded)),
        .delete(record.recordID, CKError(.networkUnavailable))]
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: reverse ? Array(failures.reversed()) : failures)
    #expect(throws: CloudTransportError.quotaExceeded) { try buffer.sendResult() }
}

@Test(arguments: [false, true], [false, true])
func mixedAtomicSaveDeleteFailurePreservesRootRecovery(unknownSave: Bool, reverse: Bool) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let card = try await repository.createCard(title: "Deleted", now: instant)
    let value = ReplicatedRecord(payload: .card(card), generation: .initial)
    let cardRecord = try recordWithServerTag(value)
    let tombstone = SyncTombstone(id: UUID(), entity: .card, entityID: card.id.rawValue, deletedAt: instant,
        deviceID: "device", revision: 2)
    let tombstoneValue = ReplicatedRecord(payload: .tombstone(tombstone), generation: .initial)
    let tombstoneRecord = try recordWithServerTag(tombstoneValue)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([cardRecord, tombstoneRecord]); buffer.beginSend()
    let failures: [FailedRecordChange] = [
        .save(tombstoneRecord, CKError(unknownSave ? .unknownItem : .batchRequestFailed)),
        .delete(cardRecord.recordID, CKError(unknownSave ? .batchRequestFailed : .unknownItem))
    ]
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: reverse ? Array(failures.reversed()) : failures)
    let result = try buffer.sendResult()
    #expect(result.requiresRefetch)
    #expect(result.savedRecordIDs.isEmpty)
    let resumed = try EngineEventBuffer(checkpoint: result.checkpoint)
    #expect(try resumed.prepare(unknownSave ? tombstoneValue : value).recordChangeTag == nil)
    #expect(try resumed.prepare(unknownSave ? value : tombstoneValue).recordChangeTag == "server-tag-before-delete")
}

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
            if firstSend { buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: [.save(record, CKError(.unknownItem))]) }
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
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: [.save(tagged, CKError(.unknownItem))])
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
    buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: [
        .save(records[1], CKError(.batchRequestFailed)), .save(records[0], CKError(.unknownItem))])
    let result = try buffer.sendResult()
    #expect(result.requiresRefetch && result.savedRecordIDs.isEmpty)
    let resumed = try EngineEventBuffer(checkpoint: result.checkpoint)
    #expect(try resumed.prepare(changes[0].record).recordChangeTag == nil)
    #expect(try resumed.prepare(changes[1].record).recordChangeTag == "server-tag-before-delete")
}

@Test func engineEventsRejectFailedFetchCheckpointAndUnappliedSendInbound() async throws {
    var buffer = try EngineEventBuffer(checkpoint: nil)
    buffer.recordFailure(CloudTransportError.networkUnavailable)
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
