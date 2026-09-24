import Foundation
import PetalCore

/// All synchronization operations exchange values; stored models remain actor-confined.
public protocol PetalSyncRepository: PetalRepository {
    func syncSnapshot() async throws -> SyncSnapshot
    func acknowledgeSync(_ sent: [OutboxChange], token: Data?) async throws
    func setSyncEnabled(_ enabled: Bool) async throws
    func applyInbound(_ records: [ReplicatedRecord], token: Data?, now: Date) async throws
    func takeUnpresentedConflicts(now: Date) async throws -> [ConflictArtifact]
    func recordSyncState(_ state: SyncState, retryAt: Date?) async throws
    func finishResetCleanup() async throws
}

public extension PetalSyncRepository {
    func acknowledgeSync(_ sent: [OutboxChange]) async throws { try await acknowledgeSync(sent, token: nil) }
}

public struct SyncSnapshot: Sendable {
    public let enabled: Bool
    public let changes: [OutboxChange]
    public let token: Data?
    public let tombstones: [SyncTombstone]
    public let generation: ResetGeneration
    public let state: SyncState
    public let retryAt: Date?
}

struct LocalSyncMetadata: Codable {
    var enabled = true
    var token: Data?
    var tombstones: [SyncTombstone] = []
    var generation = ResetGeneration.initial
    var state = SyncState.offline
    var retryAt: Date?
    var resetCleanupPending = false
}
