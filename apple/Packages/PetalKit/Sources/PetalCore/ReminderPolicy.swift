import Foundation

public enum ReminderPolicy {
    public static func nextFireDate(rule: ReminderRule, after date: Date, calendar: Calendar) -> Date? {
        switch rule {
        case .oneTime(let instant):
            return instant > date ? instant : nil
        case .daily(let localMinute, _):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(
                    hour: localMinute / 60,
                    minute: localMinute % 60,
                    second: 0
                ),
                matchingPolicy: .nextTime
            )
        }
    }
}
