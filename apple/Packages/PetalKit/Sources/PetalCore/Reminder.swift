import Foundation

public enum ReminderValidationError: Error, Sendable { case invalidRule }

public extension Reminder {
    func validate() throws {
        switch rule {
        case .oneTime(let instant):
            guard instant.timeIntervalSince1970.isFinite else { throw ReminderValidationError.invalidRule }
        case .daily(let minute, _):
            guard (0...1439).contains(minute) else { throw ReminderValidationError.invalidRule }
        }
        if let snoozedUntil, !snoozedUntil.timeIntervalSince1970.isFinite { throw ReminderValidationError.invalidRule }
    }
}

public enum ReminderRule: Codable, Sendable, Equatable {
    case oneTime(Date)
    case daily(localMinute: Int, timeZoneIdentifier: String)
}

public struct Reminder: Codable, Sendable, Equatable {
    public var rule: ReminderRule
    public var isEnabled: Bool
    public var snoozedUntil: Date?
    public var lastDeliveredAt: Date?

    public init(
        rule: ReminderRule,
        isEnabled: Bool,
        snoozedUntil: Date? = nil,
        lastDeliveredAt: Date? = nil
    ) {
        self.rule = rule
        self.isEnabled = isEnabled
        self.snoozedUntil = snoozedUntil
        self.lastDeliveredAt = lastDeliveredAt
    }
}
