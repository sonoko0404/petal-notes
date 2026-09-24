import Foundation
import Testing
import UserNotifications
import PetalCore
@testable import PetalNotifications

actor RecordingNotificationHandler: NotificationActionHandling {
    var actions: [NotificationAction] = []
    var lines: [LineID] = []
    func handle(_ action: NotificationAction, lineID: LineID, cardID: CardID) {
        actions.append(action); lines.append(lineID)
    }
}
struct NotificationBrokerTests {
    @Test func coldLaunchQueuesValidatedActionsAndDrainsInOrderOnceReady() async throws {
        let broker = NotificationResponseBroker(capacity: 2)
        let delegate = NotificationResponseDelegate(handler: broker, onFailure: { await broker.recordFailure() })
        let item = ReminderSchedulerTests().line()
        let request = try SystemNotificationCenter.makeRequest(ReminderRequest(id: "line.\(item.id.rawValue)",
            cardID: item.cardID, lineID: item.id, body: "Private", fireDate: .distantFuture, sound: false))
        let foreign = UNNotificationRequest(identifier: "other", content: request.content, trigger: request.trigger)
        await delegate.receive(request: foreign, actionIdentifier: "complete")
        await delegate.receive(request: request, actionIdentifier: "unknown")
        await delegate.receive(request: request, actionIdentifier: "snooze-5m")
        await delegate.receive(request: request, actionIdentifier: UNNotificationDefaultActionIdentifier)
        let recorder = RecordingNotificationHandler()
        #expect(await recorder.actions.isEmpty)
        await broker.install(recorder, onFailure: {})
        #expect(await recorder.actions == [.snoozeFiveMinutes, .openCard])
        #expect(await recorder.lines == [item.id, item.id])
        await delegate.receive(request: request, actionIdentifier: "complete")
        #expect(await recorder.actions == [.snoozeFiveMinutes, .openCard, .complete])
    }
    @Test func boundedQueueRejectsOverflowWithoutEvictingEarlierResponse() async throws {
        let broker = NotificationResponseBroker(capacity: 1)
        let item = ReminderSchedulerTests().line()
        try await broker.handle(.complete, lineID: item.id, cardID: item.cardID)
        await #expect(throws: (any Error).self) { try await broker.handle(.openCard, lineID: item.id, cardID: item.cardID) }
        let recorder = RecordingNotificationHandler()
        await broker.install(recorder, onFailure: {})
        #expect(await recorder.actions == [.complete])
    }
}
