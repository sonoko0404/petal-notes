import Foundation
import PetalCore
import PetalPersistence
import PetalNotifications

public enum ReminderSoundPreference {
    public static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PetalAppGroupIdentifier") as? String,
              !group.isEmpty else { return nil }
        return UserDefaults(suiteName: group)
    }
    public static var isEnabled: Bool { defaults?.bool(forKey: "notificationSoundEnabled") == true }
}

public struct ReminderWidgetTodoAction: WidgetTodoAction {
    private let openRepository: @Sendable () throws -> any PetalRepository
    public init(openRepository: @escaping @Sendable () throws -> any PetalRepository) { self.openRepository = openRepository }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        let coordinator = ReminderCoordinator(repository: try openRepository(),
            scheduler: UserNotificationScheduler(center: SystemNotificationCenter(), soundEnabled: { ReminderSoundPreference.isEnabled }))
        try await coordinator.setCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
    }
}

/// Shared app/extension service. The FIFO covers loading fresh store state, the
/// local commit, notification reconciliation, and post-commit hooks.
public actor ReminderCoordinator: NotificationActionHandling, WidgetTodoAction {
    private let repository: any PetalRepository
    private let scheduler: any ReminderScheduling
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let reloadWidgets: @Sendable () async -> Void
    private let requestSync: @Sendable () async -> Void
    private let openURL: @Sendable (URL) async -> Void
    private var tail: Task<Void, Never>?
    private var invalidationGeneration = 0
    private var reconciliation: Task<ReconcileResult, Error>?
    public init(repository: any PetalRepository, scheduler: any ReminderScheduling,
                now: @escaping @Sendable () -> Date = { .now }, calendar: @escaping @Sendable () -> Calendar = { .current },
                reloadWidgets: @escaping @Sendable () async -> Void = {}, requestSync: @escaping @Sendable () async -> Void = {},
                openURL: @escaping @Sendable (URL) async -> Void = { await PetalNavigationRequests.shared.open($0) }) {
        self.repository = repository; self.scheduler = scheduler; self.now = now; self.calendar = calendar
        self.reloadWidgets = reloadWidgets; self.requestSync = requestSync; self.openURL = openURL
    }
    private func ordered<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; return try await operation() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
    private func refresh() async throws -> ReconcileResult {
        var lines: [CardLine] = []
        for card in try await repository.cards(scope: .active) { lines += try await repository.lines(cardID: card.id) }
        return try await scheduler.reconcile(lines: lines, now: now(), calendar: calendar())
    }
    public func reconcile(_ reason: ReminderReconcileReason) async throws -> ReconcileResult {
        try await invalidate(reason).value
    }
    /// A burst shares a single drain. An invalidation arriving during a read
    /// advances the generation, forcing one more fresh pass before completion.
    public func invalidate(_ reason: ReminderReconcileReason) -> Task<ReconcileResult, Error> {
        invalidationGeneration += 1
        if let reconciliation { return reconciliation }
        let task = Task {
            return try await ordered { try await self.drainInvalidations() }
        }
        reconciliation = task
        return task
    }
    private func drainInvalidations() async throws -> ReconcileResult {
        while true {
            let generation = invalidationGeneration
            do {
                let result = try await refresh()
                if generation == invalidationGeneration {
                    reconciliation = nil
                    return result
                }
            } catch {
                if generation == invalidationGeneration {
                    reconciliation = nil
                    throw error
                }
            }
        }
    }
    public func save(lineID: LineID, reminder: Reminder?) async throws -> ReconcileResult {
        try await ordered {
            _ = try await self.repository.setReminder(lineID: lineID, reminder: reminder, now: self.now())
            await self.reloadWidgets()
            await self.requestSync()
            do {
                if reminder?.isEnabled == true { _ = try await self.scheduler.authorizeForExplicitSave() }
                return try await self.refresh()
            } catch { return .schedulingFailed }
        }
    }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        try await ordered {
            try await self.repository.setWidgetCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
            if completed { try await self.scheduler.complete(lineID: lineID) }
            await self.reloadWidgets()
            await self.requestSync()
            _ = try await self.refresh()
        }
    }
    public func handle(_ action: NotificationAction, lineID: LineID, cardID: CardID) async throws {
        try await ordered {
            guard let card = try await self.repository.card(id: cardID), card.status == .active,
                  let line = try await self.repository.lines(cardID: cardID).first(where: { $0.id == lineID }),
                  line.kind == .todo else { throw RepositoryError.lineUnavailable }
            if action == .openCard { await self.openURL(PetalDeepLink.card(cardID).url); return }
            let now = self.now()
            switch action {
            case .complete:
                try await self.repository.setWidgetCompleted(lineID: lineID, completed: true, now: now, calendar: self.calendar())
                try await self.scheduler.complete(lineID: lineID)
            case .snoozeFiveMinutes:
                guard var reminder = line.reminder, reminder.isEnabled,
                      !line.isCompleted || (line.completedAt.map { !self.calendar().isDate($0, inSameDayAs: now) } == true
                        && { if case .daily = reminder.rule { return true }; return false }()) else { throw RepositoryError.lineUnavailable }
                reminder.snoozedUntil = now.addingTimeInterval(300)
                _ = try await self.repository.setReminder(lineID: lineID, reminder: reminder, now: now)
            case .openCard: break
            }
            await self.reloadWidgets()
            await self.requestSync()
            _ = try await self.refresh()
        }
    }
}
