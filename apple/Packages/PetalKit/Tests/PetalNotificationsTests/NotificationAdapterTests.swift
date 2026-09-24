import Foundation
import Testing
import UserNotifications
import PetalCore
@testable import PetalNotifications

struct NotificationAdapterTests {
    @Test func nativeCalendarDSTContractMatchesPolicy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Explicit future transition dates let nextTriggerDate probe native behavior
        // without changing the host clock. Production daily components remain floating.
        let year = calendar.component(.year, from: .now) + 1
        let marchStart = calendar.date(from: DateComponents(year: year, month: 3, day: 8))!
        let novemberStart = calendar.date(from: DateComponents(year: year, month: 11, day: 1))!
        let spring = calendar.nextDate(after: marchStart.addingTimeInterval(-1), matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)!
        let fall = calendar.nextDate(after: novemberStart.addingTimeInterval(-1), matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)!
        for (day, minute, expectedHour, expectedMinute, expectedOffset) in [(spring, 150, 3, 30, -25200), (fall, 90, 1, 30, -25200)] {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.timeZone = calendar.timeZone
            components.hour = minute / 60; components.minute = minute % 60; components.second = 0
            let native = try #require(UNCalendarNotificationTrigger(dateMatching: components, repeats: true).nextTriggerDate())
            #expect(calendar.component(.hour, from: native) == expectedHour)
            #expect(calendar.component(.minute, from: native) == expectedMinute)
            #expect(calendar.timeZone.secondsFromGMT(for: native) == expectedOffset)
            #expect(ReminderPolicy.nextFireDate(rule: .daily(localMinute: minute, timeZoneIdentifier: "ignored"),
                after: day.addingTimeInterval(-1), calendar: calendar) == native)
        }
    }
    @Test func foreignCategoryAndMismatchedIdentifierAreRejected() throws {
        let line = LineID(rawValue: UUID())
        let request = ReminderRequest(id: "line.\(line.rawValue)", cardID: CardID(rawValue: UUID()), lineID: line,
            body: "Todo", fireDate: .distantFuture, sound: false)
        let native = try SystemNotificationCenter.makeRequest(request)
        #expect(SystemNotificationCenter.decode(UNNotificationRequest(identifier: "other", content: native.content, trigger: native.trigger)) == nil)
        #expect(NotificationResponseDelegate.action(identifier: UNNotificationDefaultActionIdentifier) == .openCard)
        #expect(NotificationResponseDelegate.action(identifier: "unknown") == nil)
    }
    @Test func dailyRequestRepeatsWithoutRefill() async throws {
        let center = FakeNotificationCenter(.authorized)
        let scheduler = UserNotificationScheduler(center: center)
        var line = ReminderSchedulerTests().line()
        line.reminder?.rule = .daily(localMinute: 570, timeZoneIdentifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        _ = try await scheduler.reconcile(lines: [line], now: Date(timeIntervalSince1970: 1_800_000_000), calendar: calendar)
        let request = try #require(await center.requests.first)
        let trigger = try #require(try SystemNotificationCenter.makeRequest(request).trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 9)
        #expect(trigger.dateComponents.minute == 30)
        #expect(trigger.dateComponents.day == nil)
        #expect(trigger.dateComponents.timeZone == nil)
        #expect(trigger.dateComponents.calendar == nil)
    }
    @Test func requestRoundTripPreservesAbsoluteTimeAndSoundDefaults() throws {
        let line = LineID(rawValue: UUID())
        let request = ReminderRequest(id: "line.\(line.rawValue)", cardID: CardID(rawValue: UUID()),
            lineID: line, body: "Private", fireDate: Date(timeIntervalSince1970: 2_000_000_000.125), sound: false)
        let native = try SystemNotificationCenter.makeRequest(request)
        #expect(native.content.sound == nil)
        #expect(native.content.categoryIdentifier == "petal.todo")
        #expect((native.trigger as? UNCalendarNotificationTrigger)?.dateComponents.timeZone?.secondsFromGMT() == 0)
        let components = try #require((native.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        #expect(components.calendar?.date(from: components) == request.fireDate)
        #expect(SystemNotificationCenter.decode(native) == request)
        #expect(Set(SystemNotificationCenter.actions().map(\.identifier)) == ["complete", "snooze-5m", "open-card"])
    }
}
