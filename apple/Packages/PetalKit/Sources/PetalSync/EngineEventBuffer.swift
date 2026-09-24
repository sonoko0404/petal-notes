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
    private var failures = CloudFailureSummary()
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
            // Remove legacy queued bare-ID deletes from a resumed engine state.
            // Permanent deletion is now a conditional, content-free entity save.
            result.excludedDeletionIDs.append(record.recordID)
        }
        return result
    }
    func checkpoint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Checkpoint(engineState: engineState, systemFields: systemFields,
            absentRecordNames: absentRecordNames.sorted()))
    }
    func fetchResult() throws -> CloudFetchResult {
        if let error = failures.error { throw error }
        return CloudFetchResult(records: inbound, token: try checkpoint())
    }
    mutating func beginSend() { inbound = []; saved = []; failures = CloudFailureSummary(); requiresRefetch = false; batchWasAborted = false }
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
        for (_, error) in failed {
            recordRetryConstraint(error)
            if error.code != .unknownItem && error.code != .batchRequestFailed { recordFailure(error) }
        }
        didSave(savedRecords)
        didDelete(deletedRecordIDs + missing)
    }
    mutating func recordFailure(_ error: any Error) {
        let summary = CKSyncTransport.summary(error)
        failures.include(summary.reason, retryAfter: summary.maxRetryAfter)
    }
    mutating func recordRetryConstraint(_ error: any Error) {
        failures.include(nil, retryAfter: CKSyncTransport.summary(error).maxRetryAfter)
    }
    private func safeFailure(_ reason: CloudTransportError) -> any Error {
        var combined = failures
        combined.include(reason)
        return combined.error ?? reason
    }
    mutating func didSave(_ records: [CKRecord]) {
        for record in records {
            absentRecordNames.remove(record.recordID.recordName)
            retainSystemFields(record)
            if let id = UUID(uuidString: record.recordID.recordName) { saved.insert(id) }
        }
    }
    func sendResult() throws -> EngineSendResult {
        guard inbound.isEmpty else { throw safeFailure(.conflict) }
        if let error = failures.error { throw error }
        if batchWasAborted && !requiresRefetch { throw safeFailure(.conflict) }
        return EngineSendResult(savedRecordIDs: saved, checkpoint: try checkpoint(), requiresRefetch: requiresRefetch,
            maxRetryAfter: failures.maxRetryAfter)
    }
}
