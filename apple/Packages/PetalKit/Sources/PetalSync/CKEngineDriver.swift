import CloudKit
import Foundation
import PetalPersistence

/// The only production transport. Engine construction is lazy so disabled sync
/// does not contact CloudKit. Automatic networking is explicitly disabled.
actor CKEngineDriver: SyncEngineDriving, CKSyncEngineDelegate {
    private let containerIdentifier: String
    private let accountStatus: @Sendable () async throws -> CKAccountStatus
    private let makeEngine: @Sendable (String, CKSyncEngine.State.Serialization?, any CKSyncEngineDelegate) throws -> CKSyncEngine
    private var engine: CKSyncEngine?
    private var epoch: UInt64 = 0
    private var engineEpoch: UInt64?
    private var buffer: EngineEventBuffer
    private var pending: [CKRecord.ID: CKRecord] = [:]
    private var deletions: [CKRecord.ID: CKRecord.ID] = [:]

    init(containerIdentifier: String,
         accountStatus: (@Sendable () async throws -> CKAccountStatus)? = nil,
         makeEngine: (@Sendable (String, CKSyncEngine.State.Serialization?, any CKSyncEngineDelegate) throws -> CKSyncEngine)? = nil) {
        self.containerIdentifier = containerIdentifier
        self.accountStatus = accountStatus ?? { try await CKContainer(identifier: containerIdentifier).accountStatus() }
        self.makeEngine = makeEngine ?? Self.privateEngine
        buffer = try! EngineEventBuffer(checkpoint: nil)
    }

    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        epoch &+= 1
        let operation = epoch
        let previous = engine; engine = nil; engineEpoch = nil
        await previous?.cancelOperations()
        try check(operation)
        // Always reconstruct from the committed checkpoint, including after a
        // repository rollback. A staged stateUpdate can never skip unapplied data.
        buffer = try EngineEventBuffer(checkpoint: checkpoint)
        let serialized = try buffer.engineState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let status = try await accountStatus()
        try check(operation)
        guard status == .available else { throw CloudTransportError.authenticationRequired }
        let engine = try makeEngine(containerIdentifier, serialized, self)
        self.engine = engine
        engineEpoch = operation
        pending = [:]; deletions = [:]
        do { try await engine.fetchChanges() }
        catch {
            try check(operation)
            buffer.recordFailure(error)
        }
        try check(operation)
        return try buffer.fetchResult()
    }

    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        let operation = epoch
        try check(operation)
        guard let engine, engineEpoch == operation else { throw CloudTransportError.unavailable }
        buffer.beginSend(); pending = [:]; deletions = [:]
        let plan = try buffer.prepareSend(records)
        pending = Dictionary(uniqueKeysWithValues: plan.records.map { ($0.recordID, $0) })
        deletions = plan.deletions
        // Also retire legacy deletes whose outbox intent was discarded by a
        // replacement. Never execute an unversioned delete from a checkpoint.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter {
            if case .deleteRecord = $0 { true } else { false }
        })
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecordMapper.zoneID))])
        engine.state.add(pendingRecordZoneChanges: pending.keys.map { .saveRecord($0) }
            + deletions.values.map { .deleteRecord($0) })
        do { try await engine.sendChanges() }
        catch {
            try check(operation)
            // An atomic operation may also throw its aggregate error after
            // delivering per-record events. Only the staged, fully accounted
            // missing-record case can expose a recovery checkpoint.
            buffer.recordRetryConstraint(error)
            if let cloud = error as? CKError, cloud.code == .partialFailure || cloud.code == .unknownItem {
                let result = try buffer.sendResult()
                if result.requiresRefetch { return result }
            }
            buffer.recordFailure(error)
            return try buffer.sendResult()
        }
        try check(operation)
        return try buffer.sendResult()
    }

    func cancel() async {
        epoch &+= 1
        let previous = engine; engine = nil; engineEpoch = nil
        pending = [:]; deletions = [:]
        await previous?.cancelOperations()
    }

    private func check(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == operation else { throw CancellationError() }
    }

    private static func privateEngine(_ identifier: String, _ serialization: CKSyncEngine.State.Serialization?,
                                      _ delegate: any CKSyncEngineDelegate) -> CKSyncEngine {
        let container = CKContainer(identifier: identifier)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
            stateSerialization: serialization, delegate: delegate)
        configuration.automaticallySync = false
        configuration.subscriptionID = "petal.private.v1"
        return CKSyncEngine(configuration)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, engineEpoch == epoch, !pending.isEmpty else { return nil }
        let records = Array(pending.values.sorted { $0.recordID.recordName < $1.recordID.recordName }.prefix(100))
        let removed = records.compactMap { deletions.removeValue(forKey: $0.recordID) }
        for record in records { pending.removeValue(forKey: record.recordID) }
        // Entity redactions are conditional saves; no business-ID deletes are
        // generated. Keep zone atomicity for related user records.
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: removed, atomicByZone: true)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine, engineEpoch == epoch else { return }
        do {
            switch event {
            case .stateUpdate(let value): buffer.engineState = try JSONEncoder().encode(value.stateSerialization)
            case .fetchedRecordZoneChanges(let value):
                try buffer.receive(value.modifications.map(\.record))
                buffer.didDelete(value.deletions.map(\.recordID))
                // Legacy physical deletions may still arrive. New clients only
                // save versioned entity redactions; fences remain merge authority.
            case .sentRecordZoneChanges(let value):
                buffer.didSend(savedRecords: value.savedRecords, deletedRecordIDs: value.deletedRecordIDs,
                    failures: value.failedRecordSaves.map { .save($0.record, $0.error) }
                        + value.failedRecordDeletes.map { .delete($0.key, $0.value) })
            case .didFetchRecordZoneChanges(let value):
                if let error = value.error { buffer.recordFailure(error) }
            case .sentDatabaseChanges(let value):
                for failed in value.failedZoneSaves { buffer.recordFailure(failed.error) }
                for error in value.failedZoneDeletes.values { buffer.recordFailure(error) }
            case .accountChange(let value):
                switch value.changeType {
                case .signIn: break
                case .signOut, .switchAccounts: buffer.recordFailure(CloudTransportError.authenticationRequired)
                @unknown default: buffer.recordFailure(CloudTransportError.accountUnavailable)
                }
            default: break
            }
        } catch { buffer.recordFailure(CloudTransportError.invalidRecord) }
    }
}

public extension CKSyncTransport {
    init(containerIdentifier: String) { self.init(engine: CKEngineDriver(containerIdentifier: containerIdentifier)) }
}
