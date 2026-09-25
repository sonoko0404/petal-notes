import Foundation

public enum CompletionPolicy {
    /// Daily completion is projected in the device's current calendar/time zone.
    /// The audit instant remains UTC; no midnight write is needed to reset UI.
    public static func isCompleted(_ line: CardLine, now: Date, calendar: Calendar) -> Bool {
        guard line.kind == .todo, line.isCompleted else { return false }
        guard case .daily = line.reminder?.rule else { return true }
        if let date = line.completedAt { return calendar.isDate(date, inSameDayAs: now) }
        return line.lastDailyCompletionKey == localDayKey(for: now, calendar: calendar)
    }

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
