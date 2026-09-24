import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

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
