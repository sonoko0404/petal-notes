import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalNotifications
import PetalSync
@testable import PetalActions

private actor Events {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
private actor Scheduler: ReminderScheduling {
    let events: Events
    init(events: Events) { self.events = events }
    func authorizeForExplicitSave() async throws -> AuthorizationState { .authorized }
    func reconcile(lines: [CardLine], now: Date, calendar: Calendar) async throws -> ReconcileResult {
        await events.add("reconcile-notifications"); return .scheduled
    }
    func cancel(lineID: LineID) async {}
    func complete(lineID: LineID) async throws {}
    func cancelAll() async throws { await events.add("cancel-notifications") }
}

private actor OfflineTransport: CloudTransport {
    var calls = 0
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult { calls += 1; throw CloudTransportError.networkUnavailable }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult { throw CloudTransportError.networkUnavailable }
}

@Test func sharedCompletionCommitsLocallyAndRequestsSyncThroughExtensionSafeRuntime() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Inbox", now: .now)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Todo"), now: .now)
    let events = Events()
    let transport = OfflineTransport()
    let runtime = SharedSyncRuntime(repository: repository, scheduler: Scheduler(events: events), transport: transport,
        reloadWidgets: { await events.add("reload-widgets") })
    try await runtime.reminders.setCompleted(lineID: line.id, completed: true, now: .now, calendar: .current)
    await runtime.sync.sync(reason: .widget)
    #expect(try await repository.lines(cardID: card.id).first?.isCompleted == true)
    #expect(try await repository.pendingOutboxCount() == 3)
    #expect(await transport.calls == 1)
    try await runtime.sync.setEnabled(false)
}

@Test func inboundCompletionOrdersFreshStoreNotificationsAndWidgets() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: .now)
    let events = Events()
    let lifecycle = AppLifecycleCoordinator(repository: repository, scheduler: Scheduler(events: events),
        refreshStore: { await events.add("refresh-store") }, reloadWidgets: { await events.add("reload-widgets") })
    try await lifecycle.handle(.inboundSyncCompleted)
    #expect(await events.values == ["refresh-store", "reconcile-notifications", "reload-widgets"])
}

@Test func resetCommitsBeforeCancelRefreshReloadAndKeepsDurableOutbox() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let old = try await repository.createCard(title: "Old", now: .now)
    let events = Events()
    let lifecycle = AppLifecycleCoordinator(repository: repository, scheduler: Scheduler(events: events),
        refreshStore: { () async throws -> Void in
            #expect(try await repository.card(id: old.id) == nil)
            await events.add("refresh-store")
        }, reloadWidgets: { await events.add("reload-widgets") })
    let reset = ResetGenerationCoordinator(repository: repository, afterCommit: { try await lifecycle.handle(.resetCompleted) })
    let result = try await reset.reset(now: .now)
    #expect(result.sideEffectsSucceeded)
    #expect(try await repository.resetGeneration() == result.generation)
    #expect(try await repository.pendingOutboxCount() == 3)
    #expect(await events.values == ["refresh-store", "cancel-notifications", "reconcile-notifications", "reload-widgets"])
}
