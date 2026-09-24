import CloudKit
import Foundation
import PetalCore
import PetalPersistence

public enum CloudRecordMapper {
    public static let zoneID = CKRecordZone.ID(zoneName: "Petal", ownerName: CKCurrentUserDefaultName)
    public static let userStateID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static func outbound(_ snapshot: SyncSnapshot) throws -> [OutboundCloudChange] {
        let groups = Dictionary(grouping: snapshot.changes.filter { $0.entity != .conflict }) {
            "\($0.entity.rawValue).\($0.entityID)"
        }
        return try groups.values.compactMap { journal in
            let ordered = journal.sorted { $0.sequence < $1.sequence }
            guard let last = ordered.last else { return nil }
            let payload: ReplicatedRecord.Payload
            if last.operation == .delete {
                guard let tombstone = snapshot.tombstones.first(where: { $0.entityID == last.entityID }) else {
                    throw CloudTransportError.invalidRecord
                }
                payload = .tombstone(tombstone)
            } else {
                switch last.entity {
                case .card: payload = .card(try JSONDecoder().decode(Card.self, from: last.payload))
                case .line: payload = .line(try JSONDecoder().decode(CardLine.self, from: last.payload))
                case .userState: payload = .userState(try JSONDecoder().decode(UserStateChange.self, from: last.payload))
                case .conflict: return nil
                }
            }
            return OutboundCloudChange(record: ReplicatedRecord(payload: payload, generation: snapshot.generation), journal: ordered)
        }.sorted { $0.journal.last!.sequence < $1.journal.last!.sequence }
    }

    public static func identity(_ record: ReplicatedRecord) -> (type: String, id: UUID, modifiedAt: Date, revision: Int64, deviceID: String) {
        switch record.payload {
        case .card(let v): ("PTCard", v.id.rawValue, v.modifiedAt, v.revision, v.deviceID)
        case .line(let v): ("PTLine", v.id.rawValue, v.modifiedAt, v.revision, v.deviceID)
        case .userState: ("PTUserState", userStateID, record.generation.modifiedAt, 1, record.generation.deviceID)
        case .tombstone(let v): ("PTTombstone", v.id, v.deletedAt, v.revision, v.deviceID)
        }
    }

    public static func encode(_ value: ReplicatedRecord) throws -> CKRecord {
        let identity = identity(value)
        let record = CKRecord(recordType: identity.type, recordID: CKRecord.ID(recordName: identity.id.uuidString, zoneID: zoneID))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Codable payload is a closed domain enum, never arbitrary settings/diagnostics.
        record["payload"] = try encoder.encode(value.payload) as CKRecordValue
        record["modifiedAt"] = identity.modifiedAt as CKRecordValue
        record["revision"] = identity.revision as CKRecordValue
        record["deviceID"] = identity.deviceID as CKRecordValue
        record["schemaVersion"] = 1 as CKRecordValue
        record["reminderVersion"] = 1 as CKRecordValue
        record["resetGeneration"] = value.generation.id.uuidString as CKRecordValue
        record["resetModifiedAt"] = value.generation.modifiedAt as CKRecordValue
        record["resetDeviceID"] = value.generation.deviceID as CKRecordValue
        // Explicit zero clears a prior server value when a later normal reset
        // updates the same PTUserState or restored card/line record identity.
        record["resetIsReplacement"] = (value.generation.isReplacement ? 1 : 0) as CKRecordValue
        return record
    }

    public static func decode(_ record: CKRecord) throws -> ReplicatedRecord {
        if record["resetIsReplacement"] != nil,
           record["resetIsReplacement"] as? Int64 != 0 && record["resetIsReplacement"] as? Int64 != 1 {
            throw CloudTransportError.invalidRecord
        }
        guard record.recordID.zoneID == zoneID,
              record["schemaVersion"] as? Int64 == 1, record["reminderVersion"] as? Int64 == 1,
              let payload = record["payload"] as? Data,
              let generation = record["resetGeneration"] as? String, let id = UUID(uuidString: generation),
              let date = record["resetModifiedAt"] as? Date, let device = record["resetDeviceID"] as? String else {
            throw CloudTransportError.invalidRecord
        }
        do {
            let value = ReplicatedRecord(payload: try JSONDecoder().decode(ReplicatedRecord.Payload.self, from: payload),
                generation: ResetGeneration(id: id, modifiedAt: date, deviceID: device,
                    isReplacement: record["resetIsReplacement"] as? Int64 == 1))
            let identity = identity(value)
            guard record.recordType == identity.type, record.recordID.recordName == identity.id.uuidString,
                  record["modifiedAt"] as? Date == identity.modifiedAt, record["revision"] as? Int64 == identity.revision,
                  record["deviceID"] as? String == identity.deviceID else { throw CloudTransportError.invalidRecord }
            if case .line(let line) = value.payload { try line.reminder?.validate() }
            return value
        } catch { throw CloudTransportError.invalidRecord }
    }
}
