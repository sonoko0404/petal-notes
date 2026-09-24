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
    private var operationEpoch: UInt64 = 0
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
        operationEpoch &+= 1
        let operation = operationEpoch
        try await repository.setSyncEnabled(enabled)
        guard operation == operationEpoch else { return }
        if !enabled {
            pendingReason = nil
            retryTask?.cancel(); retryTask = nil; deferredReason = nil; await transport.cancel()
            guard operation == operationEpoch else { return }
            state = .offline
            await stateObserver(state)
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
        let operation = operationEpoch
        var preferenceEpoch: UInt64?
        do {
            try await repository.finishResetCleanup()
            try check(operation)
            try await repository.purgeExpiredConflicts(now: now())
            try check(operation)
            try await repository.purgeExpiredTrash(now: now())
            try check(operation)
            let snapshot = try await repository.syncSnapshot()
            try check(operation)
            guard snapshot.enabled else { return }
            preferenceEpoch = snapshot.preferenceEpoch
            if let deadline = snapshot.retryAt, deadline > now() {
                scheduleRetry(after: deadline.timeIntervalSince(now())); return
            }
            try await publish(.syncing, retryAt: nil, operation: operation, preferenceEpoch: preferenceEpoch)
            try check(operation)
            let inbound = try await transport.fetchChanges(after: snapshot.token)
            try check(operation)
            guard try await repository.syncSnapshot().enabled else { return }
            try check(operation)
            try await repository.applyInbound(inbound.records, token: inbound.token, now: now(), expectedEpoch: preferenceEpoch)
            try check(operation)
            let merged = try await repository.syncSnapshot()
            try check(operation)
            if merged.generation > snapshot.generation {
                try await afterReset()
                try check(operation)
                try await repository.finishResetCleanup()
            }
            else { try await afterInbound() }
            try check(operation)
            let current = try await repository.syncSnapshot()
            try check(operation)
            guard current.enabled, current.preferenceEpoch == preferenceEpoch else { return }
            var changes = try CloudRecordMapper.outbound(current)
            if current.generation.isReplacement {
                let markers = changes.filter { if case .userState = $0.record.payload { true } else { false } }
                // CK may partially accept a non-atomic batch. Persist acceptance
                // of the replacement marker before publishing its user records.
                if !markers.isEmpty { changes = markers }
            }
            if !changes.isEmpty {
                let result = try await transport.send(changes)
                try check(operation)
                try await repository.acknowledgeSync(changes.filter { result.acceptedIDs.contains($0.id) }.flatMap(\.journal), token: result.token, expectedEpoch: preferenceEpoch)
                try check(operation)
                if let requested = result.maxRetryAfter {
                    throw CloudTransportFailure(reason: result.requiresRefetch ? .conflict : .retryAfter(requested), maxRetryAfter: requested)
                }
                if result.requiresRefetch { throw CloudTransportError.conflict }
                guard changes.allSatisfy({ result.acceptedIDs.contains($0.id) }) else { throw CloudTransportError.unavailable }
            }
            let remaining = try await repository.syncSnapshot()
            try check(operation)
            if try !CloudRecordMapper.outbound(remaining).isEmpty {
                pendingReason = pendingReason ?? .localMutation
                return
            }
            failures = 0
            try await publish(.synced(now()), retryAt: nil, operation: operation, preferenceEpoch: preferenceEpoch)
        } catch {
            guard operation == operationEpoch else { return }
            if error as? RepositoryError == .syncSessionSuperseded { return }
            if (try? await repository.syncSnapshot().enabled) == false { return }
            guard operation == operationEpoch else { return }
            let constrained = error as? CloudTransportFailure
            let typed = constrained?.reason ?? error as? CloudTransportError
            let nextState: SyncState
            switch typed {
            case .networkUnavailable: nextState = .offline
            case .authenticationRequired, .accountUnavailable: nextState = .failed(.authenticationRequired)
            case .quotaExceeded: nextState = .failed(.quotaExceeded)
            default: nextState = .failed(.other("sync-unavailable"))
            }
            failures = min(failures + 1, 8)
            var delay = min(pow(2, Double(failures)), 300)
            if case .retryAfter(let requested) = typed, requested.isFinite { delay = max(delay, requested) }
            if let requested = constrained?.maxRetryAfter { delay = max(delay, requested) }
            let retryable = constrained != nil || typed == .networkUnavailable || { if case .retryAfter = typed { return true }; return false }() || typed == .conflict
            do {
                try await publish(nextState, retryAt: retryable ? now().addingTimeInterval(delay) : nil,
                    operation: operation, preferenceEpoch: preferenceEpoch)
            } catch { return }
            guard operation == operationEpoch else { return }
            if retryable { scheduleRetry(after: delay) }
        }
    }
    private func publish(_ value: SyncState, retryAt: Date?, operation: UInt64, preferenceEpoch: UInt64?) async throws {
        try check(operation)
        try await repository.recordSyncState(value, retryAt: retryAt, expectedEpoch: preferenceEpoch)
        try check(operation)
        state = value
        await stateObserver(value)
    }
    private func check(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard operation == operationEpoch else { throw CancellationError() }
    }
    private func scheduleRetry(after delay: TimeInterval) {
        guard retryTask == nil else { return }
        let sleep = self.sleep
        let operation = operationEpoch
        retryTask = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation(); await self?.resumeRetry(operation: operation) } catch {}
        }
    }
    private func resumeRetry(operation: UInt64) async {
        guard operation == operationEpoch else { return }
        retryTask = nil
        // Do not clear the durable deadline on timer wake. Wall-clock movement
        // or an early wake must pass performSync's deadline gate again.
        let reason = deferredReason ?? .retry; deferredReason = nil
        await sync(reason: reason)
    }
}
