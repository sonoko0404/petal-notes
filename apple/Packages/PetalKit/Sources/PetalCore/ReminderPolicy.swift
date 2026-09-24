import Foundation

public enum ReminderPolicy {
    public static func nextFireDate(rule: ReminderRule, after date: Date, calendar: Calendar) -> Date? {
        switch rule {
        case .oneTime(let instant):
            return instant > date ? instant : nil
        case .daily(let localMinute, _):
            let matching = DateComponents(hour: localMinute / 60, minute: localMinute % 60, second: 0)
            let todayStart = calendar.startOfDay(for: date)
            guard let firstToday = calendar.nextDate(
                after: todayStart.addingTimeInterval(-1),
                matching: matching,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first
            ) else { return nil }
            if firstToday > date { return firstToday }

            guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
                return nil
            }
            return calendar.nextDate(
                after: tomorrowStart.addingTimeInterval(-1),
                matching: matching,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first
            )
        }
    }
}
