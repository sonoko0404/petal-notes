import Foundation
import Testing
import PetalCore
import PetalNotifications
import PetalPersistence
import PetalActions

private actor DeliveredCleanupCenter: NotificationCenterAdapter {
    enum Failure: Error { case unavailable }
    var pendingValues: [ReminderRequest] = []
    var deliveredValues: [ReminderRequest]
    var failDeliveredOnce: Bool
    init(_ delivered: [ReminderRequest], failDeliveredOnce: Bool = false) {
        deliveredValues = delivered; self.failDeliveredOnce = failDeliveredOnce
    }
    func authorization() -> AuthorizationState { .authorized }
    func requestAuthorization() -> AuthorizationState { .authorized }
    func pending() -> [ReminderRequest] { pendingValues }
    func deliveredRequests() throws -> [ReminderRequest] {
        if failDeliveredOnce { failDeliveredOnce = false; throw Failure.unavailable }
        return deliveredValues
    }
    func add(_ request: ReminderRequest) { pendingValues.append(request) }
    func remove(_ ids: [String]) {
        pendingValues.removeAll { ids.contains($0.id) && $0.isPetalOwned }
        removeDelivered(ids)
    }
    func removeDelivered(_ ids: [String]) { deliveredValues.removeAll { ids.contains($0.id) && $0.isPetalOwned } }
    func registerActions() {}
}

struct DeliveredNotificationCleanupTests {
    @Test func nextInboundLifecycleRepairsDeliveredCleanupAfterResetEffectsFailed() async throws {
        let lineID = LineID(rawValue: UUID()), cardID = CardID(rawValue: UUID())
        let owned = ReminderRequest(id: ReminderRequest.baseID(lineID), cardID: cardID, lineID: lineID,
            body: "Private reminder", fireDate: .distantPast, sound: false)
        let center = DeliveredCleanupCenter([owned], failDeliveredOnce: true)
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let lifecycle = AppLifecycleCoordinator(repository: repository, scheduler: UserNotificationScheduler(center: center), reloadWidgets: {})
        await #expect(throws: DeliveredCleanupCenter.Failure.self) { try await lifecycle.handle(.resetCompleted) }
        #expect(await center.deliveredValues == [owned])
        try await lifecycle.handle(.inboundSyncCompleted)
        #expect(await center.deliveredValues.isEmpty)
    }

    @Test func resetRemovesDeliveredOnlyPetalRequestsWhilePreservingForeignCategories() async throws {
        let lineID = LineID(rawValue: UUID()), cardID = CardID(rawValue: UUID())
        let owned = ReminderRequest(id: ReminderRequest.baseID(lineID), cardID: cardID, lineID: lineID,
            body: "Private reminder", fireDate: .distantPast, sound: false)
        let foreign = ReminderRequest(id: ReminderRequest.baseID(lineID), cardID: cardID, lineID: lineID,
            body: "Unrelated", fireDate: .distantPast, sound: false, category: "other")
        let center = DeliveredCleanupCenter([owned, foreign])
        try await UserNotificationScheduler(center: center).cancelAll()
        #expect(await center.deliveredValues == [foreign])
    }

    @Test func resetRetriesDeliveredEnumerationFailureWithoutForgettingRequests() async throws {
        let lineID = LineID(rawValue: UUID()), cardID = CardID(rawValue: UUID())
        let owned = ReminderRequest(id: ReminderRequest.baseID(lineID), cardID: cardID, lineID: lineID,
            body: "Private reminder", fireDate: .distantPast, sound: false)
        let center = DeliveredCleanupCenter([owned], failDeliveredOnce: true)
        let scheduler = UserNotificationScheduler(center: center)
        await #expect(throws: DeliveredCleanupCenter.Failure.self) { try await scheduler.cancelAll() }
        #expect(await center.deliveredValues == [owned])
        try await scheduler.cancelAll()
        #expect(await center.deliveredValues.isEmpty)
    }
}
