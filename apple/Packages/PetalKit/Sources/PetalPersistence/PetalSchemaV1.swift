import Foundation
import SwiftData
import PetalCore

// Stored types are implementation details. Only Codable domain values leave the actor.
enum PetalSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredCard.self, StoredLine.self, StoredOutboxChange.self, StoredConflictArtifact.self,
         StoredImportFingerprint.self, StoredUserState.self]
    }

    @Model final class StoredImportFingerprint {
        @Attribute(.unique) var fingerprint: String
        var importedAt: Date
        init(fingerprint: String, importedAt: Date) {
            self.fingerprint = fingerprint
            self.importedAt = importedAt
        }
    }

    @Model final class StoredUserState {
        @Attribute(.unique) var key: String
        var resetGeneration: UUID?
        var deviceID: String
        var nextOutboxSequence: Int64
        init(resetGeneration: UUID?) {
            key = "user-state"
            self.resetGeneration = resetGeneration
            deviceID = UUID().uuidString
            nextOutboxSequence = 0
        }
    }

    @Model final class StoredConflictArtifact {
        @Attribute(.unique) var id: UUID
        var expiresAt: Date
        var payload: Data
        init(_ value: ConflictArtifact) throws {
            id = value.id
            expiresAt = value.expiresAt
            payload = try JSONEncoder().encode(value)
        }
        func value() throws -> ConflictArtifact { try JSONDecoder().decode(ConflictArtifact.self, from: payload) }
    }

    @Model final class StoredLine {
        @Attribute(.unique) var id: UUID
        var cardID: UUID
        var payload: Data
        init(_ value: CardLine) throws {
            id = value.id.rawValue
            cardID = value.cardID.rawValue
            payload = try JSONEncoder().encode(value)
        }
        func value() throws -> CardLine { try JSONDecoder().decode(CardLine.self, from: payload) }
    }

    @Model final class StoredOutboxChange {
        @Attribute(.unique) var id: UUID
        var payload: Data
        init(_ value: OutboxChange) throws {
            id = value.id
            payload = try JSONEncoder().encode(value)
        }
        func value() throws -> OutboxChange { try JSONDecoder().decode(OutboxChange.self, from: payload) }
    }

    @Model final class StoredCard {
        @Attribute(.unique) var id: UUID
        var payload: Data
        init(_ value: Card) throws {
            id = value.id.rawValue
            payload = try JSONEncoder().encode(value)
        }
        func value() throws -> Card { try JSONDecoder().decode(Card.self, from: payload) }
    }
}
