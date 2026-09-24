import Foundation
import CloudKit
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func anotherInstanceToggleDuringSendFencesOldAcknowledgement() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Keep pending", now: now)
    let transport = FakeCloudTransport()
    await transport.onNextSend {
        try await repository.setSyncEnabled(false)
        try await repository.setSyncEnabled(true)
    }
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, now: { now })
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.syncSnapshot().token == Data([42]))
    #expect(await coordinator.state != .synced(now))
}

@Test func disabledSendCompletionCannotAcknowledgeOrPublishSynced() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Still pending", now: now)
    let transport = FakeCloudTransport()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    await transport.onNextSend { try await coordinator.setEnabled(false) }
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.syncSnapshot().token == Data([42]))
    #expect(try await repository.syncSnapshot().state == .offline)
    #expect(await coordinator.state == .offline)
}

@Test func disableReenableDuringFetchCannotApplyOldPass() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Local", now: now)
    var old = card; old.title = "Obsolete fetch"; old.modifiedAt = now.addingTimeInterval(1)
    let transport = FakeCloudTransport(inbound: [ReplicatedRecord(payload: .card(old), generation: .initial)])
    await transport.holdFirstFetch()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    let running = await coordinator.request(reason: .foreground)
    await transport.waitForFetch()
    try await coordinator.setEnabled(false)
    let reenabling = Task { try await coordinator.setEnabled(true) }
    // Synchronize on the persisted preference, not a wall-clock sleep.
    while try !(await repository.syncSnapshot().enabled) { await Task.yield() }
    await transport.replaceFutureInbound([])
    await transport.releaseFetch()
    await running.value; try await reenabling.value
    #expect(try await repository.card(id: card.id)?.title == "Local")
    #expect(await transport.calls == ["fetch", "fetch", "send"])
}

@Test func syncPassPurgesThirtyDayTrashWithDurableDeletionFence() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Inbox", now: now)
    let card = try await repository.createCard(title: "Expired trash", now: now)
    try await repository.moveCard(card.id, to: .trashed, replacementInbox: nil, now: now.addingTimeInterval(-2_592_000))
    try await repository.setSyncEnabled(false)
    let transport = FakeCloudTransport()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, now: { now })
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.card(id: card.id) == nil)
    #expect(try await repository.syncSnapshot().tombstones.contains { $0.entityID == card.id.rawValue })
    #expect(await transport.calls.isEmpty)
}

@Test func syncPassPurgesExpiredConflictPayloadEvenWhenDisabled() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Current", now: now)
    _ = try await repository.captureConflict(cardID: card.id, lineID: nil, losingPayload: Data("Expired conflict".utf8), now: now.addingTimeInterval(-2_592_000))
    try await repository.setSyncEnabled(false)
    let transport = FakeCloudTransport()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, now: { now })
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.conflicts().isEmpty)
    #expect(try await repository.pendingOutbox().filter { $0.entity == .conflict }.allSatisfy { $0.operation == .delete && $0.payload.isEmpty })
    #expect(await transport.calls.isEmpty)
}

@Test func disablingDuringFetchDiscardsLateBatchAndDoesNotSend() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Local", now: now)
    var remote = card; remote.title = "Remote"; remote.modifiedAt = now.addingTimeInterval(1)
    let transport = FakeCloudTransport(inbound: [ReplicatedRecord(payload: .card(remote), generation: .initial)])
    await transport.holdFirstFetch()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    let task = await coordinator.request(reason: .foreground)
    await transport.waitForFetch()
    try await coordinator.setEnabled(false)
    await transport.releaseFetch(); await task.value
    #expect(try await repository.card(id: card.id)?.title == "Local")
    #expect(try await repository.syncSnapshot().token == nil)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(await transport.calls == ["fetch"])
}

@Test func lifecycleEditIsIncludedInCurrentOutboxSend() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Initial", now: now)
    let transport = FakeCloudTransport()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, afterInbound: {
        _ = try await repository.updateCardTitle(card.id, title: "Edited during refresh", now: now.addingTimeInterval(1))
    })
    await coordinator.sync(reason: .foreground)
    let sent = await transport.sent
    if case .card(let value) = try #require(sent.first).record.payload { #expect(value.title == "Edited during refresh") }
    else { Issue.record("Expected latest card") }
    #expect(try await repository.pendingOutboxCount() == 0)
}

private actor SleepProbe {
    var delays: [TimeInterval] = []
    var waiting: CheckedContinuation<Void, Never>?
    func sleep(_ seconds: TimeInterval) async throws {
        delays.append(seconds); waiting?.resume(); waiting = nil
        try await Task.sleep(for: .seconds(3600))
    }
    func waitUntilScheduled() async { if delays.isEmpty { await withCheckedContinuation { waiting = $0 } } }
}

private final class RetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}

private actor EarlyWakeProbe {
    private(set) var delays: [TimeInterval] = []
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(_ delay: TimeInterval) async throws {
        delays.append(delay); waiter?.resume(); waiter = nil
        if delays.count == 1 { await withCheckedContinuation { held = $0 } }
        else { try await Task.sleep(for: .seconds(3600)) }
    }
    func waitForFirstSchedule() async { if delays.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func wake() { held?.resume(); held = nil }
}

@Test func retryWakeRechecksPersistedDeadlineBeforeTransport() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let transport = FakeCloudTransport(failure: .retryAfter(120))
    let clock = RetryClock(now)
    let probe = EarlyWakeProbe()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, now: { clock.read() },
        sleep: { try await probe.sleep($0) })
    await coordinator.sync(reason: .launch)
    await probe.waitForFirstSchedule()
    clock.set(now.addingTimeInterval(119))
    await transport.clearFailure()
    await probe.wake()
    // Wait for either outcome, not a timer: the broken path makes a second fetch;
    // the correct path schedules the remaining second without contacting CloudKit.
    while await probe.delays.count < 2 {
        if await transport.calls.count >= 2 { break }
        await Task.yield()
    }
    #expect(await transport.calls == ["fetch"])
    #expect(await probe.delays == [120, 1])
    #expect(try await repository.syncSnapshot().retryAt == now.addingTimeInterval(120))
    try await coordinator.setEnabled(false)
}

@Test func retryAfterDefersTransportWithoutBlockingEditsAndPersistsSafeState() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Initial", now: now)
    let transport = FakeCloudTransport(failure: .retryAfter(120))
    let sleeper = SleepProbe()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, now: { now }, sleep: { try await sleeper.sleep($0) })
    await coordinator.sync(reason: .foreground)
    await sleeper.waitUntilScheduled()
    _ = try await repository.updateCardTitle(card.id, title: "Still editable", now: now)
    await coordinator.sync(reason: .localMutation)
    #expect(await transport.calls == ["fetch"])
    #expect(await sleeper.delays == [120])
    #expect(try await repository.syncSnapshot().retryAt == now.addingTimeInterval(120))
    #expect(try await repository.syncSnapshot().state == .failed(.other("sync-unavailable")))
    try await coordinator.setEnabled(false)
    #expect(try await repository.syncSnapshot().retryAt == now.addingTimeInterval(120))
    try await coordinator.setEnabled(true)
    #expect(await transport.calls == ["fetch"])
    try await coordinator.setEnabled(false)
    #expect(try await repository.card(id: card.id)?.title == "Still editable")
}

@Test func localBackoffIsNotShortenedBySmallServerRetryHint() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let probe = SleepProbe()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: FakeCloudTransport(failure: .retryAfter(1)),
        now: { now }, sleep: { try await probe.sleep($0) })
    await coordinator.sync(reason: .launch)
    await probe.waitUntilScheduled()
    #expect(await probe.delays == [2])
    #expect(try await repository.syncSnapshot().retryAt == now.addingTimeInterval(2))
    try await coordinator.setEnabled(false)
}

private actor FakeCloudTransport: CloudTransport {
    var failure: CloudTransportError?
    var inbound: [ReplicatedRecord] = []
    var calls: [String] = []
    var sent: [OutboundCloudChange] = []
    var sendFailure: CloudTransportError?
    var acceptNone = false
    var duringSend: (@Sendable () async throws -> Void)?
    func onNextSend(_ action: @escaping @Sendable () async throws -> Void) { duringSend = action }
    func failSend(_ error: CloudTransportError) { sendFailure = error }
    func rejectSend() { acceptNone = true }
    var holdFirst = false
    var held: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func holdFirstFetch() { holdFirst = true }
    func waitForFetch() async { if calls.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func releaseFetch() { held?.resume(); held = nil }
    func clearFailure() { failure = nil }
    func replaceFutureInbound(_ values: [ReplicatedRecord]) { inbound = values }
    init(failure: CloudTransportError? = nil, inbound: [ReplicatedRecord] = []) {
        self.failure = failure; self.inbound = inbound
    }
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        calls.append("fetch")
        let fetched = inbound
        waiter?.resume(); waiter = nil
        if holdFirst { holdFirst = false; await withCheckedContinuation { held = $0 } }
        if let failure { throw failure }
        return CloudFetchResult(records: fetched, token: Data([42]))
    }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        calls.append("send"); sent = changes
        let action = duringSend; duringSend = nil; try await action?()
        if let sendFailure { throw sendFailure }
        return CloudSendResult(acceptedIDs: acceptNone ? [] : Set(changes.map(\.id)), token: Data([43]))
    }
}

@Test func editDuringSendRemainsPendingAndIsSentInAnotherFreshPass() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Old", now: now)
    let transport = FakeCloudTransport()
    await transport.onNextSend { _ = try await repository.updateCardTitle(card.id, title: "Newer", now: now.addingTimeInterval(1)) }
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    await coordinator.sync(reason: .foreground)
    #expect(await transport.calls == ["fetch", "send", "fetch", "send"])
    #expect(try await repository.pendingOutboxCount() == 0)
    let sent = await transport.sent
    if case .card(let value) = try #require(sent.first).record.payload { #expect(value.title == "Newer") }
    else { Issue.record("Expected latest card") }
}

@Test func committedInboundEffectsRunBeforeSendAndSendCheckpointIsAcknowledged() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Pending", now: now)
    let transport = FakeCloudTransport()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport, afterInbound: { () async throws -> Void in
        #expect(try await repository.syncSnapshot().token == Data([42]))
        #expect(await transport.calls == ["fetch"])
    })
    await coordinator.sync(reason: .foreground)
    #expect(await transport.calls == ["fetch", "send"])
    #expect(try await repository.syncSnapshot().token == Data([43]))
    #expect(try await repository.pendingOutboxCount() == 0)
}

@Test func unacknowledgedSendDoesNotReportSyncedAndResetSurvivesCloudFailure() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Old", now: now)
    try await repository.deleteAllData(resetGeneration: UUID(), now: now)
    let transport = FakeCloudTransport()
    await transport.rejectSend()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    await coordinator.sync(reason: .foreground)
    #expect(await coordinator.state == .failed(.other("sync-unavailable")))
    #expect(try await repository.pendingOutboxCount() == 3)
    #expect(try await repository.cards(scope: .active).count == 1)
    #expect(try await repository.syncSnapshot().token == Data([43]))
}

@Test func coalescedRequestsRunFreshPassAndKeepNewestReason() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Initial", now: now)
    let transport = FakeCloudTransport()
    await transport.holdFirstFetch()
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    let first = await coordinator.request(reason: .foreground)
    await transport.waitForFetch()
    for _ in 0..<20 { _ = await coordinator.request(reason: .localMutation) }
    _ = try await repository.updateCardTitle(card.id, title: "Newest", now: now.addingTimeInterval(1))
    let last = await coordinator.request(reason: .push)
    await transport.releaseFetch()
    await first.value; await last.value
    #expect(await transport.calls == ["fetch", "send", "fetch"])
    #expect(await coordinator.lastCompletedReason == .push)
    #expect(try await repository.pendingOutboxCount() == 0)
    let sent = await transport.sent
    if case .card(let value) = try #require(sent.first).record.payload { #expect(value.title == "Newest") }
    else { Issue.record("Expected a card") }
}

@Test func offlineFailureKeepsOutboxAndLocalEditAndReportsNoRawError() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Local edit", now: now)
    let transport = FakeCloudTransport(failure: .networkUnavailable)
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.card(id: card.id)?.title == "Local edit")
    #expect(try await repository.syncSnapshot().token == nil)
    #expect(await coordinator.state == .offline)
    #expect(await transport.calls == ["fetch"])
}

@Test func disabledSyncRetainsOutboxAndReenableFetchesBeforeSendingMergedWinner() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Local", now: now)
    var remote = card; remote.title = "Remote winner"; remote.modifiedAt = now.addingTimeInterval(1); remote.deviceID = "remote"
    let transport = FakeCloudTransport(inbound: [ReplicatedRecord(payload: .card(remote), generation: .initial)])
    let coordinator = CloudSyncCoordinator(repository: repository, transport: transport)
    try await coordinator.setEnabled(false)
    await coordinator.sync(reason: .foreground)
    #expect(await transport.calls.isEmpty)
    #expect(try await repository.pendingOutboxCount() == 1)
    try await coordinator.setEnabled(true)
    #expect(await transport.calls == ["fetch"])
    #expect(try await repository.card(id: card.id)?.title == "Remote winner")
    #expect(try await repository.pendingOutboxCount() == 0)
    #expect(try await repository.syncSnapshot().token == Data([42]))
}

@Test func mapperUploadsOnlyLatestDomainRecordsAndRoundTripsUTCAndVersions() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Private", now: now)
    _ = try await repository.updateCardTitle(card.id, title: "Latest", now: now.addingTimeInterval(1))
    _ = try await repository.captureConflict(cardID: card.id, lineID: nil, losingPayload: Data("local artifact".utf8), now: now)
    let changes = try CloudRecordMapper.outbound(try await repository.syncSnapshot())
    #expect(changes.count == 1)
    let change = try #require(changes.first)
    let ck = try CloudRecordMapper.encode(change.record)
    #expect(ck.recordType == "PTCard")
    #expect(ck.recordID.recordName == card.id.rawValue.uuidString)
    #expect(ck["modifiedAt"] as? Date == now.addingTimeInterval(1))
    #expect(ck["schemaVersion"] as? Int64 == 1)
    #expect(ck["reminderVersion"] as? Int64 == 1)
    #expect(Set(ck.allKeys()) == Set(["payload", "modifiedAt", "revision", "deviceID", "schemaVersion", "reminderVersion", "resetGeneration", "resetModifiedAt", "resetDeviceID", "resetIsReplacement", "isDeleted", "redactionVersion"]))
    #expect(try CloudRecordMapper.decode(ck) == change.record)
    ck["schemaVersion"] = 2 as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(ck) }
    _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Todo"), now: now)
    let lineChange = try #require(CloudRecordMapper.outbound(try await repository.syncSnapshot()).first { if case .line = $0.record.payload { return true }; return false })
    #expect(try CloudRecordMapper.encode(lineChange.record).recordType == "PTLine")
    #expect(try CloudRecordMapper.decode(CloudRecordMapper.encode(lineChange.record)) == lineChange.record)
    try await repository.deleteAllData(resetGeneration: UUID(), now: now.addingTimeInterval(10))
    let resetChanges = try CloudRecordMapper.outbound(try await repository.syncSnapshot())
    #expect(try Set(resetChanges.map { try CloudRecordMapper.encode($0.record).recordType }) == Set(["PTCard", "PTUserState", "PTLine"]))
    for change in resetChanges { #expect(try CloudRecordMapper.decode(CloudRecordMapper.encode(change.record)) == change.record) }
}
