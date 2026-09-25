import Foundation
import PetalCore

public struct UserStateChange: Codable, Sendable, Equatable {
    public let resetGeneration: UUID
    public let inboxCardID: CardID
    public let replacementMode: Bool?
    public let revision: Int64?
    public let modifiedAt: Date?
    public let deviceID: String?
    public init(resetGeneration: UUID, inboxCardID: CardID, replacementMode: Bool? = nil,
                revision: Int64? = nil, modifiedAt: Date? = nil, deviceID: String? = nil) {
        self.resetGeneration = resetGeneration; self.inboxCardID = inboxCardID
        self.replacementMode = replacementMode; self.revision = revision; self.modifiedAt = modifiedAt; self.deviceID = deviceID
    }
    public func resolved(in generation: ResetGeneration) -> Self {
        Self(resetGeneration: resetGeneration, inboxCardID: inboxCardID,
            replacementMode: replacementMode ?? generation.isReplacement, revision: revision ?? 1,
            modifiedAt: modifiedAt ?? generation.modifiedAt, deviceID: deviceID ?? generation.deviceID)
    }
    public func isNewer(than other: Self, in generation: ResetGeneration) -> Bool {
        let a = resolved(in: generation), b = other.resolved(in: generation)
        if a.revision != b.revision { return a.revision! > b.revision! }
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt! > b.modifiedAt! }
        if a.deviceID != b.deviceID { return a.deviceID! > b.deviceID! }
        if a.replacementMode != b.replacementMode { return a.replacementMode == false }
        return a.inboxCardID.rawValue.uuidString > b.inboxCardID.rawValue.uuidString
    }
}

public struct OutboxChange: Identifiable, Codable, Sendable, Equatable {
    public enum Entity: String, Codable, Sendable { case card, line, userState, conflict }
    public enum Operation: String, Codable, Sendable { case upsert, delete }
    public let id: UUID
    public let entity: Entity
    public let entityID: UUID
    public let operation: Operation
    public let payload: Data
    public let createdAt: Date
    public let sequence: Int64
}

public enum RepositoryError: Error, Equatable, Sendable {
    case injectedFailure
    case cardUnavailable
    case lineUnavailable
    case invalidOrder
    case replacementInboxRequired
    case appGroupUnavailable
    case unsupportedSchema(Int)
    case unrecognizedStoreSchema
    case unresolvedInboundCapacityExceeded
    case syncSessionSuperseded
}

public enum RepositoryFaultInjector: Sendable {
    case none
    case failBeforeSave
    case failOnceBeforeSave
}
