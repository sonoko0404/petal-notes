import Foundation
import Testing
@testable import PetalCore

@Test func completedTodoIsVisibleTodayAndHiddenTomorrow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let completed = Date(timeIntervalSince1970: 1_799_323_200)

    #expect(CompletionPolicy.isVisibleInWidget(completedAt: completed, now: completed, calendar: calendar))
    #expect(!CompletionPolicy.isVisibleInWidget(
        completedAt: completed,
        now: calendar.date(byAdding: .day, value: 1, to: completed)!,
        calendar: calendar
    ))
}

@Test func localDayKeyUsesTheInjectedTimeZone() {
    let instant = ISO8601DateFormatter().date(from: "2026-09-23T00:30:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    #expect(CompletionPolicy.localDayKey(for: instant, calendar: calendar) == "2026-09-22")

    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    #expect(CompletionPolicy.localDayKey(for: instant, calendar: calendar) == "2026-09-23")
}

@Test func uncompletedTodoRemainsVisible() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(CompletionPolicy.isVisibleInWidget(completedAt: nil, now: now, calendar: .current))
}
