import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport
import PetalNotifications
import PetalActions

actor ActionEvents {
    var values: [String] = []
    var urls: [URL] = []
    func append(_ value: String) { values.append(value) }
    func open(_ url: URL) { urls.append(url) }
}
struct ReminderCoordinatorTests {
    @Test func schedulingFailureIsSeparateFromDurableSave() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        let center = FakeNotificationCenter(.authorized)
        await center.failScheduling()
        let coordinator = ReminderCoordinator(repository: f.repository, scheduler: UserNotificationScheduler(center: center))
        let reminder = Reminder(rule: .oneTime(.distantFuture), isEnabled: true)
        #expect(try await coordinator.save(lineID: line.id, reminder: reminder) == .schedulingFailed)
        #expect(try await f.repository.lines(cardID: line.cardID).first?.reminder == reminder)
    }
    @Test func failedCommitDoesNotPromptOrSchedule() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let repo = SwiftDataPetalRepository(container: store)
        let card = try await repo.createCard(title: "Card", now: .now)
        let line = try await repo.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Todo"), now: .now)
        let center = FakeNotificationCenter(.notDetermined)
        let failing = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
        let coordinator = ReminderCoordinator(repository: failing, scheduler: UserNotificationScheduler(center: center))
        await #expect(throws: RepositoryError.injectedFailure) {
            _ = try await coordinator.save(lineID: line.id, reminder: Reminder(rule: .oneTime(.distantFuture), isEnabled: true))
        }
        #expect(await center.authorizationRequests == 0)
        #expect(await center.requests.isEmpty)
        #expect(try await repo.lines(cardID: card.id).first?.reminder == nil)
    }
    @Test func laterSnoozeOnlyReplacesSnooze() async throws {
        let now = DeterministicClock.referenceDate
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        let first = ReminderCoordinator(repository: f.repository, scheduler: scheduler, now: { now })
        _ = try await first.save(lineID: line.id, reminder: Reminder(rule: .oneTime(now.addingTimeInterval(900)), isEnabled: true))
        try await first.handle(.snoozeFiveMinutes, lineID: line.id, cardID: line.cardID)
        let second = ReminderCoordinator(repository: f.repository, scheduler: scheduler, now: { now.addingTimeInterval(60) })
        try await second.handle(.snoozeFiveMinutes, lineID: line.id, cardID: line.cardID)
        #expect(await center.requests.count == 2)
        #expect(await center.additions == 3)
        #expect(await center.requests.first { $0.id.hasSuffix(".snooze") }?.fireDate == now.addingTimeInterval(360))
    }
    @Test func deniedSavePersistsAndBackgroundNeverPrompts() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        let center = FakeNotificationCenter(.denied)
        let coordinator = ReminderCoordinator(repository: f.repository, scheduler: UserNotificationScheduler(center: center))
        let reminder = Reminder(rule: .oneTime(.distantFuture), isEnabled: true)
        let result = try await coordinator.save(lineID: line.id, reminder: reminder)
        #expect(result == .permissionDenied)
        #expect(try await f.repository.lines(cardID: f.fixtureCardID).first?.reminder == reminder)
        for reason in ReminderReconcileReason.allCases { _ = try await coordinator.reconcile(reason) }
        #expect(await center.authorizationRequests == 0)
    }
    @Test func actionsCompleteSnoozeAndOpenSafelyWithHooks() async throws {
        let now = DeterministicClock.referenceDate
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        let center = FakeNotificationCenter(.authorized)
        let events = ActionEvents()
        let coordinator = ReminderCoordinator(repository: f.repository, scheduler: UserNotificationScheduler(center: center),
            now: { now }, calendar: { .current }, reloadWidgets: { await events.append("reload") },
            requestSync: { await events.append("sync") }, openURL: { await events.open($0) })
        _ = try await coordinator.save(lineID: line.id, reminder: Reminder(rule: .oneTime(now.addingTimeInterval(900)), isEnabled: true))
        try await coordinator.handle(.snoozeFiveMinutes, lineID: line.id, cardID: line.cardID)
        try await coordinator.handle(.snoozeFiveMinutes, lineID: line.id, cardID: line.cardID)
        #expect(await center.requests.count == 2)
        #expect(await center.requests.first { $0.id.hasSuffix(".snooze") }?.fireDate == now.addingTimeInterval(300))
        try await coordinator.handle(.openCard, lineID: line.id, cardID: line.cardID)
        #expect(await events.urls.first == PetalDeepLink.card(line.cardID).url)
        try await coordinator.handle(.complete, lineID: line.id, cardID: line.cardID)
        #expect(try await f.repository.lines(cardID: line.cardID).first?.isCompleted == true)
        #expect(await center.requests.isEmpty)
        #expect(await events.values.suffix(2) == ["reload", "sync"])
    }
}
