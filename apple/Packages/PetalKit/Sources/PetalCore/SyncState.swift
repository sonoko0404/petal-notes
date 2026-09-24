import Foundation

public struct ConflictArtifact: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let cardID: CardID
    public let lineID: LineID?
    public let losingPayload: Data
    public let capturedAt: Date
    public let expiresAt: Date
    public var hasBeenPresented: Bool
    public let inboundIssue: StructuralIssue?

    public init(
        id: UUID, cardID: CardID, lineID: LineID?, losingPayload: Data,
        capturedAt: Date, expiresAt: Date, hasBeenPresented: Bool, inboundIssue: StructuralIssue? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.lineID = lineID
        self.losingPayload = losingPayload
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.hasBeenPresented = hasBeenPresented
        self.inboundIssue = inboundIssue
    }
}

public enum SyncFailure: Codable, Sendable, Equatable {
    case authenticationRequired
    case networkUnavailable
    case quotaExceeded
    case other(String)
}

public enum SyncState: Codable, Sendable, Equatable {
    case synced(Date)
    case syncing
    case offline
    case failed(SyncFailure)
}
