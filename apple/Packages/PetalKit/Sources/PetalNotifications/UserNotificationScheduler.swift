import Foundation
import PetalCore

public actor UserNotificationScheduler: ReminderScheduling {
    private let center: any NotificationCenterAdapter
    private let soundEnabled: @Sendable () -> Bool
    private var authorizationTask: Task<AuthorizationState, Error>?
    private var tail: Task<Void, Never>?
    public init(center: any NotificationCenterAdapter, soundEnabled: @escaping @Sendable () -> Bool = { false }) {
        self.center = center; self.soundEnabled = soundEnabled
    }
    /// Call only after a successful explicit save. Background reconciliation never prompts.
    public func authorizeForExplicitSave() async throws -> AuthorizationState {
        if let authorizationTask { return try await authorizationTask.value }
        let task = Task { [center] in
            let state = await center.authorization()
            return state == .notDetermined ? try await center.requestAuthorization() : state
        }
        authorizationTask = task
        defer { authorizationTask = nil }
        return try await task.value
    }
    public func reconcile(lines: [CardLine], now: Date, calendar: Calendar) async throws -> ReconcileResult {
        let preceding = tail
        let task = Task { [center, soundEnabled] in
            await preceding?.value
            await center.registerActions()
            let state = await center.authorization()
            let allPending = try await center.pending()
            let pending = allPending.filter(\.isPetalOwned)
            var desired: [ReminderRequest] = []
            if state == .authorized {
                for line in lines where line.kind == .todo && line.deletedAt == nil {
                    guard let reminder = line.reminder, reminder.isEnabled else { continue }
                    try reminder.validate()
                    if line.isCompleted {
                        guard case .daily = reminder.rule, let completed = line.completedAt,
                              !calendar.isDate(completed, inSameDayAs: now) else { continue }
                    }
                    let base = ReminderRequest.baseID(line.id)
                    if let date = ReminderPolicy.nextFireDate(rule: reminder.rule, after: now, calendar: calendar) {
                        var request = ReminderRequest(id: base, cardID: line.cardID, lineID: line.id,
                            body: line.text, fireDate: date, sound: soundEnabled())
                        if case .daily(let minute, _) = reminder.rule {
                            request.dailyComponents = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                hour: minute / 60, minute: minute % 60, second: 0)
                        }
                        desired.append(request)
                    }
                    if let snooze = reminder.snoozedUntil, snooze > now {
                        desired.append(ReminderRequest(id: base + ".snooze", cardID: line.cardID, lineID: line.id,
                            body: line.text, fireDate: snooze, sound: soundEnabled()))
                    }
                }
            }
            let ids = Set(desired.map(\.id))
            guard !allPending.contains(where: { !$0.isPetalOwned && ids.contains($0.id) }) else {
                throw ReminderSchedulingError.identifierCollision
            }
            await center.remove(pending.filter { !ids.contains($0.id) }.map(\.id))
            for request in desired where !pending.contains(request) { try await center.add(request) }
            switch state {
            case .authorized: return ReconcileResult.scheduled
            case .denied: return .permissionDenied
            case .notDetermined: return .permissionRequired
            }
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
    public func cancel(lineID: LineID) async {
        let preceding = tail
        let task = Task { [center] in
            await preceding?.value
            let base = ReminderRequest.baseID(lineID)
            await center.remove([base, base + ".snooze"])
        }
        tail = task
        await task.value
    }
    public func cancelAll() async throws {
        let preceding = tail
        let task = Task { [center] in
            await preceding?.value
            await center.remove(try await center.pending().filter(\.isPetalOwned).map(\.id))
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
