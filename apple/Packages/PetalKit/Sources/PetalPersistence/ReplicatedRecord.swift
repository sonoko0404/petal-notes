import Foundation
import PetalCore

public struct ResetGeneration: Codable, Sendable, Equatable, Comparable {
    public let id: UUID
    public let modifiedAt: Date
    public let deviceID: String
    public init(id: UUID, modifiedAt: Date, deviceID: String) {
        self.id = id; self.modifiedAt = modifiedAt; self.deviceID = deviceID
    }
    public static let initial = ResetGeneration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        modifiedAt: Date(timeIntervalSince1970: 0), deviceID: "")
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct ReplicatedRecord: Codable, Sendable, Equatable {
    public enum Payload: Codable, Sendable, Equatable { case card(Card), line(CardLine), tombstone(SyncTombstone), userState(UserStateChange) }
    public let payload: Payload
    public let generation: ResetGeneration
    public init(payload: Payload, generation: ResetGeneration) { self.payload = payload; self.generation = generation }
}

public struct SyncTombstone: Codable, Sendable, Equatable {
    public enum Entity: String, Codable, Sendable { case card, line }
    public let id: UUID
    public let entity: Entity
    public let entityID: UUID
    public let deletedAt: Date
    public let deviceID: String
    public let revision: Int64
    public var expiresAt: Date { deletedAt.addingTimeInterval(2_592_000) }
    public init(id: UUID, entity: Entity, entityID: UUID, deletedAt: Date, deviceID: String, revision: Int64) {
        self.id = id; self.entity = entity; self.entityID = entityID
        self.deletedAt = deletedAt; self.deviceID = deviceID; self.revision = revision
    }
    public func prevents(modifiedAt: Date, deviceID: String, now: Date) -> Bool {
        expiresAt > now || deletedAt > modifiedAt || (deletedAt == modifiedAt && self.deviceID >= deviceID)
    }
}
