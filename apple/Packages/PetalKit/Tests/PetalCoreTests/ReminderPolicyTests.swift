import Foundation
import Testing
@testable import PetalCore

@Test func oneTimeReminderKeepsItsAbsoluteInstant() {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ReminderPolicy.nextFireDate(
        rule: .oneTime(instant), after: instant.addingTimeInterval(-1), calendar: .current
    ) == instant)
}

@Test func expiredOneTimeReminderHasNoNextFireDate() {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ReminderPolicy.nextFireDate(
        rule: .oneTime(instant), after: instant, calendar: .current
    ) == nil)
}

@Test func dailyReminderUsesTheInjectedCurrentTimeZone() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let after = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8, minute: 59))!
    let expected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!

    #expect(ReminderPolicy.nextFireDate(
        rule: .daily(localMinute: 540, timeZoneIdentifier: "Asia/Shanghai"),
        after: after,
        calendar: calendar
    ) == expected)
}

@Test func dailyReminderAtTheExactMinuteFiresTomorrow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let after = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!
    let expected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9))!

    #expect(ReminderPolicy.nextFireDate(
        rule: .daily(localMinute: 540, timeZoneIdentifier: "Asia/Shanghai"),
        after: after,
        calendar: calendar
    ) == expected)
}

@Test func dailyReminderAdvancesThroughSpringDaylightSavingGap() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let after = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59))!
    let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3))!

    #expect(ReminderPolicy.nextFireDate(
        rule: .daily(localMinute: 150, timeZoneIdentifier: "America/Los_Angeles"),
        after: after,
        calendar: calendar
    ) == expected)
}
