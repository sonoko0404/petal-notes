import CloudKit
import Foundation
import PetalPersistence

/// The only production transport. Engine construction is lazy so disabled sync
/// does not contact CloudKit. Automatic networking is explicitly disabled.
actor CKEngineDriver: SyncEngineDriving, CKSyncEngineDelegate {
    private let containerIdentifier: String
    private var engine: CKSyncEngine?
    private var buffer: EngineEventBuffer
    private var pending: [CKRecord.ID: CKRecord] = [:]
    private var deletions: [CKRecord.ID: CKRecord.ID] = [:]

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        buffer = try! EngineEventBuffer(checkpoint: nil)
    }

    func fetch(checkpoint: Data?) async throws -> CloudFetchResult {
        await engine?.cancelOperations()
        // Always reconstruct from the committed checkpoint, including after a
        // repository rollback. A staged stateUpdate can never skip unapplied data.
        buffer = try EngineEventBuffer(checkpoint: checkpoint)
        let serialized = try buffer.engineState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CloudTransportError.authenticationRequired }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
            stateSerialization: serialized, delegate: self)
        configuration.automaticallySync = false
        configuration.subscriptionID = "petal.private.v1"
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        pending = [:]; deletions = [:]
        try await engine.fetchChanges()
        return try buffer.fetchResult()
    }

    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult {
        guard let engine else { throw CloudTransportError.unavailable }
        buffer.beginSend(); pending = [:]; deletions = [:]
        for value in records {
            let record = try buffer.prepare(value)
            pending[record.recordID] = record
            if case .tombstone(let tombstone) = value.payload {
                deletions[record.recordID] = CKRecord.ID(recordName: tombstone.entityID.uuidString, zoneID: CloudRecordMapper.zoneID)
            }
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecordMapper.zoneID))])
        engine.state.add(pendingRecordZoneChanges: pending.keys.map { .saveRecord($0) }
            + deletions.values.map { .deleteRecord($0) })
        try await engine.sendChanges()
        return try buffer.sendResult()
    }

    func cancel() async { await engine?.cancelOperations(); engine = nil }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, !pending.isEmpty else { return nil }
        let records = Array(pending.values.sorted { $0.recordID.recordName < $1.recordID.recordName }.prefix(100))
        let removed = records.compactMap { deletions.removeValue(forKey: $0.recordID) }
        for record in records { pending.removeValue(forKey: record.recordID) }
        // Each deletion and its tombstone share the atomic custom-zone batch.
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: removed, atomicByZone: true)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        do {
            switch event {
            case .stateUpdate(let value): buffer.engineState = try JSONEncoder().encode(value.stateSerialization)
            case .fetchedRecordZoneChanges(let value):
                try buffer.receive(value.modifications.map(\.record))
                // Physical deletes are accompanied by PTTombstone in the same
                // atomic zone transaction; tombstones are the merge authority.
            case .sentRecordZoneChanges(let value):
                buffer.didSave(value.savedRecords)
                if let failure = value.failedRecordSaves.first?.error ?? value.failedRecordDeletes.values.first {
                    buffer.failure = CKSyncTransport.failure(failure)
                }
            case .didFetchRecordZoneChanges(let value):
                if let error = value.error { buffer.failure = CKSyncTransport.failure(error) }
            case .sentDatabaseChanges(let value):
                if let error = value.failedZoneSaves.first?.error ?? value.failedZoneDeletes.values.first {
                    buffer.failure = CKSyncTransport.failure(error)
                }
            case .accountChange(let value):
                switch value.changeType {
                case .signIn: break
                case .signOut, .switchAccounts: buffer.failure = .authenticationRequired
                @unknown default: buffer.failure = .accountUnavailable
                }
            default: break
            }
        } catch { buffer.failure = .invalidRecord }
    }
}

public extension CKSyncTransport {
    init(containerIdentifier: String) { self.init(engine: CKEngineDriver(containerIdentifier: containerIdentifier)) }
}
