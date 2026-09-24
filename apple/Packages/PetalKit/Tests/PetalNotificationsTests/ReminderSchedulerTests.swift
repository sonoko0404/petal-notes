import Foundation
import Testing
import PetalCore
@testable import PetalNotifications

actor FakeNotificationCenter: NotificationCenterAdapter {
    enum Failure: Error { case scheduling }
    var failAdd = false
    func failScheduling() { failAdd = true }
    var state: AuthorizationState
    var requests: [ReminderRequest] = []
    var authorizationRequests = 0
    var additions = 0
    var removals: [String] = []
    var delivered: [String] = []
    var pendingReads = 0
    private var holdPending = false
    private var pendingGate: CheckedContinuation<Void, Never>?
    private var pendingStarted: CheckedContinuation<Void, Never>?
    func holdNextPendingRead() { holdPending = true }
    func waitForHeldPendingRead() async {
        if pendingGate != nil { return }
        await withCheckedContinuation { pendingStarted = $0 }
    }
    func releasePendingRead() { pendingGate?.resume(); pendingGate = nil }
    func deliver(_ id: String) { delivered.append(id) }
    init(_ state: AuthorizationState) { self.state = state }
    func authorization() -> AuthorizationState { state }
    func requestAuthorization() -> AuthorizationState { authorizationRequests += 1; state = .authorized; return state }
    func pending() async -> [ReminderRequest] {
        pendingReads += 1
        if holdPending {
            holdPending = false
            await withCheckedContinuation {
                pendingGate = $0
                pendingStarted?.resume(); pendingStarted = nil
            }
        }
        return requests
    }
    func add(_ request: ReminderRequest) throws {
        if failAdd { throw Failure.scheduling }
        requests.removeAll { $0.id == request.id }; requests.append(request); additions += 1
    }
    func remove(_ ids: [String]) { removals += ids; requests.removeAll { ids.contains($0.id) }; delivered.removeAll { ids.contains($0) } }
    func removeDelivered(_ ids: [String]) { delivered.removeAll { ids.contains($0) } }
    func registerActions() {}
}

struct ReminderSchedulerTests {
    @Test func foreignCategoryWithSameIDCannotBeOverwritten() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        let item = line()
        let foreign = ReminderRequest(id: "line.\(item.id.rawValue)", cardID: item.cardID, lineID: item.id,
            body: "Other", fireDate: .distantFuture, sound: false, category: "other")
        try await center.add(foreign)
        await #expect(throws: (any Error).self) { _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current) }
        #expect(await center.requests == [foreign])
    }
    @Test func cancelAllIsScopedAndSoundIsOptIn() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center, soundEnabled: { true })
        let item = line()
        let foreign = ReminderRequest(id: "line.\(item.id.rawValue)", cardID: item.cardID, lineID: item.id,
            body: "Other", fireDate: .distantFuture, sound: false, category: "other")
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        #expect(await center.requests.first?.sound == true)
        try await center.add(foreign)
        try await scheduler.cancelAll()
        #expect(await center.requests == [foreign])
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func line() -> CardLine {
        CardLine(id: LineID(rawValue: UUID()), cardID: CardID(rawValue: UUID()), kind: .todo,
            text: "Todo", sortIndex: 0, isCompleted: false, completedAt: nil,
            lastDailyCompletionKey: nil, dailyStreak: 0,
            reminder: Reminder(rule: .oneTime(now.addingTimeInterval(600)), isEnabled: true),
            createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: "test")
    }
    @Test func reconciliationNeverPromptsAndExplicitSavePromptsOnce() async throws {
        let center = FakeNotificationCenter(.notDetermined)
        let scheduler = UserNotificationScheduler(center: center)
        #expect(try await scheduler.reconcile(lines: [line()], now: now, calendar: .current) == .permissionRequired)
        #expect(await center.authorizationRequests == 0)
        _ = try await scheduler.authorizeForExplicitSave()
        _ = try await scheduler.authorizeForExplicitSave()
        #expect(await center.authorizationRequests == 1)
    }
    @Test func deniedSchedulesNothing() async throws {
        let center = FakeNotificationCenter(.denied)
        let scheduler = UserNotificationScheduler(center: center)
        #expect(try await scheduler.reconcile(lines: [line()], now: now, calendar: .current) == .permissionDenied)
        #expect(await center.requests.isEmpty)
        #expect(await center.authorizationRequests == 0)
    }
    @Test func diffPreservesUnchangedAndForeignAndReplacesChangedThenCancelsCompleted() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        var item = line()
        let foreign = ReminderRequest(id: "other", cardID: item.cardID, lineID: item.id,
            body: "Unrelated", fireDate: now.addingTimeInterval(900), sound: false, category: "other")
        try await center.add(foreign)
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        #expect(await center.additions == 2)
        #expect(await center.requests.contains { $0.id == "line.\(item.id.rawValue.uuidString)" && !$0.sound })
        _ = try await scheduler.reconcile(lines: [item], now: now.addingTimeInterval(5), calendar: .current)
        #expect(await center.additions == 2)
        item.text = "Changed"
        item.reminder?.snoozedUntil = now.addingTimeInterval(300)
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        #expect(await center.additions == 4)
        item.isCompleted = true; item.completedAt = now
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        #expect(await center.requests == [foreign])
    }
    @Test func dailyDSTAndAbsoluteInstant() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let parser = ISO8601DateFormatter()
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        var item = line()
        item.reminder = Reminder(rule: .daily(localMinute: 150, timeZoneIdentifier: "UTC"), isEnabled: true)
        _ = try await scheduler.reconcile(lines: [item], now: parser.date(from: "2026-03-08T09:00:00Z")!, calendar: calendar)
        #expect(await center.requests.first?.fireDate == parser.date(from: "2026-03-08T10:30:00Z"))
        item.reminder?.rule = .daily(localMinute: 90, timeZoneIdentifier: "UTC")
        _ = try await scheduler.reconcile(lines: [item], now: parser.date(from: "2026-11-01T08:45:00Z")!, calendar: calendar)
        #expect(await center.requests.first?.fireDate == parser.date(from: "2026-11-02T09:30:00Z"))
        item.reminder?.rule = .oneTime(now.addingTimeInterval(123))
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: calendar)
        #expect(await center.requests.first?.fireDate == now.addingTimeInterval(123))
    }
    @Test func unchangedRepeatingScheduleIsNotReplacedNextDay() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        var item = line()
        item.reminder?.rule = .daily(localMinute: 600, timeZoneIdentifier: "UTC")
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        _ = try await scheduler.reconcile(lines: [item], now: now.addingTimeInterval(86400), calendar: .current)
        #expect(await center.additions == 1)
    }
    @Test func earlyDailyCompletionKeepsIndefiniteRepeatButRemovesSnooze() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        var item = line()
        item.reminder?.rule = .daily(localMinute: 1439, timeZoneIdentifier: "UTC")
        item.reminder?.snoozedUntil = now.addingTimeInterval(300)
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        item.isCompleted = true; item.completedAt = now
        _ = try await scheduler.reconcile(lines: [item], now: now, calendar: .current)
        let remaining = try #require(await center.requests.first)
        #expect(await center.requests.count == 1)
        #expect(remaining.id == "line.\(item.id.rawValue)")
        #expect(remaining.dailyComponents != nil)
        #expect(await center.additions == 2)
        try await scheduler.cancelAll()
        #expect(await center.requests.isEmpty)
    }
}
