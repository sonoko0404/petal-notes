import Foundation
import PetalPersistence

public struct ResetResult: Sendable {
    public let generation: UUID
    public let sideEffectsSucceeded: Bool
}
public struct ResetGenerationCoordinator: Sendable {
    private let repository: any PetalSyncRepository
    private let afterCommit: @Sendable () async throws -> Void
    private let requestSync: @Sendable () async -> Void
    public init(repository: any PetalSyncRepository, afterCommit: @escaping @Sendable () async throws -> Void,
                requestSync: @escaping @Sendable () async -> Void = {}) {
        self.repository = repository; self.afterCommit = afterCommit; self.requestSync = requestSync
    }
    public func reset(now: Date) async throws -> ResetResult {
        let generation = UUID()
        try await repository.deleteAllData(resetGeneration: generation, now: now)
        var succeeded = true
        do { try await repository.finishResetCleanup() } catch { succeeded = false }
        do { try await afterCommit() } catch { succeeded = false }
        await requestSync()
        return ResetResult(generation: generation, sideEffectsSucceeded: succeeded)
    }
}
