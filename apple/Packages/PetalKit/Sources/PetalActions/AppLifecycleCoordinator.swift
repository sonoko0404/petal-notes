import Foundation
import PetalCore
import PetalPersistence
import PetalNotifications

public enum AppLifecycleEvent: Sendable { case inboundSyncCompleted, resetCompleted }

/// Shared by App and extension; never imports an executable target. All effects
/// observe an already committed mutation and finish in this explicit order.
public actor AppLifecycleCoordinator {
    private let repository: any PetalRepository
    private let scheduler: any ReminderScheduling
    private let refreshStore: @Sendable () async throws -> Void
    private let reloadWidgets: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private var tail: Task<Void, Error>?
    public init(repository: any PetalRepository, scheduler: any ReminderScheduling,
        refreshStore: @escaping @Sendable () async throws -> Void = {},
        reloadWidgets: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = { .now }, calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.repository = repository; self.scheduler = scheduler; self.refreshStore = refreshStore
        self.reloadWidgets = reloadWidgets; self.now = now; self.calendar = calendar
    }
    public func handle(_ event: AppLifecycleEvent) async throws {
        let previous = tail
        let task = Task {
            _ = try? await previous?.value
            do {
                try await self.refreshStore()
                var lines: [CardLine] = []
                for card in try await self.repository.cards(scope: .active) {
                    lines += try await self.repository.lines(cardID: card.id)
                }
                if case .resetCompleted = event { try await self.scheduler.cancelAll() }
                _ = try await self.scheduler.reconcile(lines: lines, now: self.now(), calendar: self.calendar())
            } catch {
                await self.reloadWidgets()
                throw error
            }
            await self.reloadWidgets()
        }
        tail = task
        try await task.value
    }
}
