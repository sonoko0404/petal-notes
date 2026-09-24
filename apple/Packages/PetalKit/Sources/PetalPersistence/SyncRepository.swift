import Foundation
import PetalCore

public enum ReplacementDeliveryStatus: String, Codable, Sendable {
    case awaitingDeclaration, awaitingInbox, awaitingValidInitialInbox, complete
}

/// All synchronization operations exchange values; stored models remain actor-confined.
public protocol PetalSyncRepository: PetalRepository {
    func syncSnapshot() async throws -> SyncSnapshot
    func acknowledgeSync(_ sent: [OutboxChange], token: Data?, expectedEpoch: UInt64?) async throws
    func setSyncEnabled(_ enabled: Bool) async throws
    func applyInbound(_ records: [ReplicatedRecord], token: Data?, now: Date, expectedEpoch: UInt64?) async throws
    func takeUnpresentedConflicts(now: Date) async throws -> [ConflictArtifact]
    func recordSyncState(_ state: SyncState, retryAt: Date?, expectedEpoch: UInt64?) async throws
    func finishResetCleanup() async throws
}

public extension PetalSyncRepository {
    func acknowledgeSync(_ sent: [OutboxChange]) async throws { try await acknowledgeSync(sent, token: nil) }
    func acknowledgeSync(_ sent: [OutboxChange], token: Data?) async throws {
        try await acknowledgeSync(sent, token: token, expectedEpoch: nil)
    }
    func applyInbound(_ records: [ReplicatedRecord], token: Data?, now: Date) async throws {
        try await applyInbound(records, token: token, now: now, expectedEpoch: nil)
    }
    func recordSyncState(_ state: SyncState, retryAt: Date?) async throws {
        try await recordSyncState(state, retryAt: retryAt, expectedEpoch: nil)
    }
}

public struct SyncSnapshot: Sendable {
    public let enabled: Bool
    public let changes: [OutboxChange]
    public let token: Data?
    public let tombstones: [SyncTombstone]
    public let generation: ResetGeneration
    public let state: SyncState
    public let retryAt: Date?
    public let preferenceEpoch: UInt64
    public var replacementExpectedInboxID: UUID? = nil
    public var replacementDeliveryStatus: ReplacementDeliveryStatus? = nil
}

struct LocalSyncMetadata: Codable {
    var replacementPlaceholderID: UUID?
    var replacementExpectedInboxID: UUID?
    var authoritativeUserState: UserStateChange?
    var replacementInitialDeliveryComplete: Bool?
    var replacementInitialInboxIDs: Set<UUID>?
    var replacementDeliveryStatus: ReplacementDeliveryStatus?
    var enabled = true
    var token: Data?
    var tombstones: [SyncTombstone] = []
    var generation = ResetGeneration.initial
    var state = SyncState.offline
    var retryAt: Date?
    var resetCleanupPending = false
    // Optional for compatibility with already persisted V2 metadata. Never uploaded.
    var unresolvedLines: [ReplicatedRecord]?
    var preferenceEpoch: UInt64?
}
