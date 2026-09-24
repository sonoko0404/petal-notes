import CloudKit
import Foundation
import PetalPersistence

/// This checkpoint is LOCAL ONLY. StateUpdate events remain staged until the
/// repository commits the corresponding inbound batch or send acknowledgement.
struct EngineEventBuffer: Sendable {
    private struct Checkpoint: Codable {
        var version = 1
        var engineState: Data?
        var systemFields: [String: Data]
    }
    var engineState: Data?
    private var systemFields: [String: Data] = [:]
    private(set) var inbound: [ReplicatedRecord] = []
    var failure: CloudTransportError?
    private var saved: Set<UUID> = []
    init(checkpoint: Data?) throws {
        guard let checkpoint else { return }
        do {
            let saved = try JSONDecoder().decode(Checkpoint.self, from: checkpoint)
            guard saved.version == 1 else { throw CloudTransportError.invalidRecord }
            engineState = saved.engineState; systemFields = saved.systemFields
        } catch { throw CloudTransportError.invalidRecord }
    }
    mutating func receive(_ records: [CKRecord]) throws {
        for record in records {
            inbound.append(try CloudRecordMapper.decode(record))
            retainSystemFields(record)
        }
    }
    mutating func retainSystemFields(_ record: CKRecord) {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive); archive.finishEncoding()
        systemFields[record.recordID.recordName] = archive.encodedData
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
    func checkpoint() throws -> Data {
        try JSONEncoder().encode(Checkpoint(engineState: engineState, systemFields: systemFields))
    }
    func fetchResult() throws -> CloudFetchResult {
        if let failure { throw failure }
        return CloudFetchResult(records: inbound, token: try checkpoint())
    }
    mutating func beginSend() { inbound = []; saved = []; failure = nil }
    mutating func didSave(_ records: [CKRecord]) {
        for record in records {
            retainSystemFields(record)
            if let id = UUID(uuidString: record.recordID.recordName) { saved.insert(id) }
        }
    }
    func sendResult() throws -> EngineSendResult {
        guard inbound.isEmpty else { throw CloudTransportError.conflict }
        if let failure { throw failure }
        return EngineSendResult(savedRecordIDs: saved, checkpoint: try checkpoint())
    }
}
