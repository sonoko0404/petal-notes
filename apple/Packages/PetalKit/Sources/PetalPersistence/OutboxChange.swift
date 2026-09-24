import Foundation
import PetalCore

public struct UserStateChange: Codable, Sendable, Equatable {
    public let resetGeneration: UUID
    public let inboxCardID: CardID
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
}

public enum RepositoryFaultInjector: Sendable {
    case none
    case failBeforeSave
    case failOnceBeforeSave
}
