import Foundation

public enum CompletionPolicy {
    public static func localDayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func isVisibleInWidget(completedAt: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let completedAt else { return true }
        return localDayKey(for: completedAt, calendar: calendar)
            == localDayKey(for: now, calendar: calendar)
    }
}
