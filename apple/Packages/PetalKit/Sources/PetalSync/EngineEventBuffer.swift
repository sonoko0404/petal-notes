import CloudKit
import Foundation
import PetalPersistence

enum FailedRecordChange: Sendable {
    case save(CKRecord, CKError)
    case delete(CKRecord.ID, CKError)
}

struct PreparedEngineSend: Sendable {
    var records: [CKRecord]
    var deletions: [CKRecord.ID: CKRecord.ID]
    var excludedDeletionIDs: [CKRecord.ID]
}

/// This checkpoint is LOCAL ONLY. StateUpdate events remain staged until the
/// repository commits the corresponding inbound batch or send acknowledgement.
struct EngineEventBuffer: Sendable {
    private struct Checkpoint: Codable {
        var version = 1
        var engineState: Data?
        var systemFields: [String: Data]
        var absentRecordNames: [String]?
    }
    var engineState: Data?
    private var systemFields: [String: Data] = [:]
    private var absentRecordNames: Set<String> = []
    private(set) var inbound: [ReplicatedRecord] = []
    var failure: CloudTransportError?
    private var saved: Set<UUID> = []
    private var requiresRefetch = false
    private var batchWasAborted = false
    init(checkpoint: Data?) throws {
        guard let checkpoint else { return }
        do {
            let saved = try JSONDecoder().decode(Checkpoint.self, from: checkpoint)
            guard saved.version == 1 else { throw CloudTransportError.invalidRecord }
            engineState = saved.engineState; systemFields = saved.systemFields
            absentRecordNames = Set(saved.absentRecordNames ?? [])
        } catch { throw CloudTransportError.invalidRecord }
    }
    mutating func receive(_ records: [CKRecord]) throws {
        for record in records {
            inbound.append(try CloudRecordMapper.decode(record))
            absentRecordNames.remove(record.recordID.recordName)
            retainSystemFields(record)
        }
    }
    mutating func retainSystemFields(_ record: CKRecord) {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive); archive.finishEncoding()
        systemFields[record.recordID.recordName] = archive.encodedData
    }
    mutating func didDelete(_ ids: [CKRecord.ID]) {
        for id in ids {
            systemFields.removeValue(forKey: id.recordName)
            absentRecordNames.insert(id.recordName)
        }
    }
    func prepare(_ value: ReplicatedRecord) throws -> CKRecord {
        let fresh = try CloudRecordMapper.encode(value)
        guard let data = systemFields[fresh.recordID.recordName] else { return fresh }
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        guard let restored = CKRecord(coder: decoder), restored.recordType == fresh.recordType else { throw CloudTransportError.invalidRecord }
        for key in fresh.allKeys() { restored[key] = fresh[key] }
        return restored
    }
    func prepareSend(_ values: [ReplicatedRecord]) throws -> PreparedEngineSend {
        var result = PreparedEngineSend(records: [], deletions: [:], excludedDeletionIDs: [])
        for value in values {
            let record = try prepare(value)
            result.records.append(record)
            if case .tombstone(let tombstone) = value.payload {
                let target = CKRecord.ID(recordName: tombstone.entityID.uuidString, zoneID: CloudRecordMapper.zoneID)
                if absentRecordNames.contains(target.recordName) { result.excludedDeletionIDs.append(target) }
                else { result.deletions[record.recordID] = target }
            }
        }
        return result
    }
    func checkpoint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Checkpoint(engineState: engineState, systemFields: systemFields,
            absentRecordNames: absentRecordNames.sorted()))
    }
    func fetchResult() throws -> CloudFetchResult {
        if let failure { throw failure }
        return CloudFetchResult(records: inbound, token: try checkpoint())
    }
    mutating func beginSend() { inbound = []; saved = []; failure = nil; requiresRefetch = false; batchWasAborted = false }
    mutating func didSend(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], failures: [FailedRecordChange]) {
        // Reduce the complete event before selecting a result. Secondary atomic
        // aborts can never overwrite a sibling's recoverable root cause.
        let failed = failures.map { item -> (CKRecord.ID, CKError) in
            switch item {
            case .save(let record, let error): return (record.recordID, error)
            case .delete(let id, let error): return (id, error)
            }
        }
        let missing = failed.filter { $0.1.code == .unknownItem }.map(\.0)
        requiresRefetch = requiresRefetch || !missing.isEmpty
        batchWasAborted = batchWasAborted || failed.contains { $0.1.code == .batchRequestFailed }
        let substantive = failed.filter { $0.1.code != .unknownItem && $0.1.code != .batchRequestFailed }
            .map { CKSyncTransport.failure($0.1) } + [failure].compactMap { $0 }
        failure = substantive.max { Self.failurePriority($0) < Self.failurePriority($1) }
        didSave(savedRecords)
        didDelete(deletedRecordIDs + missing)
    }
    private static func failurePriority(_ error: CloudTransportError) -> (Int, TimeInterval) {
        switch error {
        case .authenticationRequired: (9, 0)
        case .accountUnavailable: (8, 0)
        case .quotaExceeded: (7, 0)
        case .networkUnavailable: (6, 0)
        case .invalidRecord: (5, 0)
        case .unavailable: (4, 0)
        case .conflict: (3, 0)
        case .retryAfter(let delay): (2, delay)
        }
    }
    mutating func didSave(_ records: [CKRecord]) {
        for record in records {
            absentRecordNames.remove(record.recordID.recordName)
            retainSystemFields(record)
            if let id = UUID(uuidString: record.recordID.recordName) { saved.insert(id) }
        }
    }
    func sendResult() throws -> EngineSendResult {
        guard inbound.isEmpty else { throw CloudTransportError.conflict }
        if let failure { throw failure }
        if batchWasAborted && !requiresRefetch { throw CloudTransportError.conflict }
        return EngineSendResult(savedRecordIDs: saved, checkpoint: try checkpoint(), requiresRefetch: requiresRefetch)
    }
}
