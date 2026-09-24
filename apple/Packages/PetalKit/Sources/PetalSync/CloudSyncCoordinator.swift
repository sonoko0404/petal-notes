import Foundation
import PetalCore
import PetalPersistence

public enum SyncReason: Sendable, Equatable { case launch, foreground, userRequested, localMutation, widget, push, enabled, retry }

public actor CloudSyncCoordinator {
    private let repository: any PetalSyncRepository
    private let transport: any CloudTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let afterInbound: @Sendable () async throws -> Void
    private let afterReset: @Sendable () async throws -> Void
    private var retryTask: Task<Void, Never>?
    private var deferredReason: SyncReason?
    private var failures = 0
    private var stateObserver: @Sendable (SyncState) async -> Void = { _ in }
    private var pendingReason: SyncReason?
    private var running: Task<Void, Never>?
    public private(set) var lastCompletedReason: SyncReason?
    public private(set) var state: SyncState = .offline
    public init(repository: any PetalSyncRepository, transport: any CloudTransport, now: @escaping @Sendable () -> Date = { .now },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                afterInbound: @escaping @Sendable () async throws -> Void = {},
                afterReset: @escaping @Sendable () async throws -> Void = {}) {
        self.repository = repository; self.transport = transport; self.now = now
        self.sleep = sleep
        self.afterInbound = afterInbound; self.afterReset = afterReset
    }
    public func setEnabled(_ enabled: Bool) async throws {
        try await repository.setSyncEnabled(enabled)
        if !enabled {
            retryTask?.cancel(); retryTask = nil; deferredReason = nil; await transport.cancel()
            state = .offline
            let deadline = try await repository.syncSnapshot().retryAt
            try await repository.recordSyncState(state, retryAt: deadline); await stateObserver(state)
        }
        if enabled { await sync(reason: .enabled) }
    }
    public func observeState(_ observer: @escaping @Sendable (SyncState) async -> Void) async {
        stateObserver = observer
        await observer((try? await repository.syncSnapshot().state) ?? state)
    }
    public func sync(reason: SyncReason) async {
        await request(reason: reason).value
    }
    public func request(reason: SyncReason) -> Task<Void, Never> {
        if retryTask != nil { deferredReason = reason; return Task {} }
        pendingReason = reason
        if let running { return running }
        let task = Task { await self.drain() }
        running = task
        return task
    }
    private func drain() async {
        while let reason = pendingReason {
            pendingReason = nil
            await performSync()
            lastCompletedReason = reason
            if retryTask != nil { deferredReason = pendingReason ?? reason; pendingReason = nil; break }
        }
        running = nil
    }
    private func performSync() async {
        do {
            try await repository.finishResetCleanup()
            try await repository.purgeExpiredConflicts(now: now())
            try await repository.purgeExpiredTrash(now: now())
            let snapshot = try await repository.syncSnapshot()
            guard snapshot.enabled else { return }
            if let deadline = snapshot.retryAt, deadline > now() {
                scheduleRetry(after: deadline.timeIntervalSince(now())); return
            }
            state = .syncing
            try await repository.recordSyncState(state, retryAt: nil)
            await stateObserver(state)
            let inbound = try await transport.fetchChanges(after: snapshot.token)
            guard try await repository.syncSnapshot().enabled else { return }
            try await repository.applyInbound(inbound.records, token: inbound.token, now: now())
            let merged = try await repository.syncSnapshot()
            if merged.generation > snapshot.generation {
                try await afterReset()
                try await repository.finishResetCleanup()
            }
            else { try await afterInbound() }
            let current = try await repository.syncSnapshot()
            guard current.enabled else { return }
            let changes = try CloudRecordMapper.outbound(current)
            if !changes.isEmpty {
                let result = try await transport.send(changes)
                try await repository.acknowledgeSync(changes.filter { result.acceptedIDs.contains($0.id) }.flatMap(\.journal), token: result.token)
                guard changes.allSatisfy({ result.acceptedIDs.contains($0.id) }) else { throw CloudTransportError.unavailable }
            }
            if try !CloudRecordMapper.outbound(await repository.syncSnapshot()).isEmpty {
                pendingReason = pendingReason ?? .localMutation
                return
            }
            state = .synced(now())
            failures = 0
            try await repository.recordSyncState(state, retryAt: nil)
            await stateObserver(state)
        } catch {
            if (try? await repository.syncSnapshot().enabled) == false { return }
            let typed = error as? CloudTransportError
            switch typed {
            case .networkUnavailable: state = .offline
            case .authenticationRequired, .accountUnavailable: state = .failed(.authenticationRequired)
            case .quotaExceeded: state = .failed(.quotaExceeded)
            default: state = .failed(.other("sync-unavailable"))
            }
            failures = min(failures + 1, 8)
            var delay = min(pow(2, Double(failures)), 300)
            if case .retryAfter(let requested) = typed, requested.isFinite { delay = max(delay, requested) }
            let retryable = typed == .networkUnavailable || { if case .retryAfter = typed { return true }; return false }() || typed == .conflict
            try? await repository.recordSyncState(state, retryAt: retryable ? now().addingTimeInterval(delay) : nil)
            await stateObserver(state)
            if retryable { scheduleRetry(after: delay) }
        }
    }
    private func scheduleRetry(after delay: TimeInterval) {
        guard retryTask == nil else { return }
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation(); await self?.resumeRetry() } catch {}
        }
    }
    private func resumeRetry() async {
        retryTask = nil
        try? await repository.recordSyncState(state, retryAt: nil)
        let reason = deferredReason ?? .retry; deferredReason = nil
        await sync(reason: reason)
    }
}
