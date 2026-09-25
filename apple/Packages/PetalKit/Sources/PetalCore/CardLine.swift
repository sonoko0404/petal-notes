import Foundation

public struct CardLine: Identifiable, Codable, Sendable, Equatable {
    public let id: LineID
    public let cardID: CardID
    public var kind: LineKind
    public var text: String
    public var sortIndex: Int64
    public var isCompleted: Bool
    public var completedAt: Date?
    public var lastDailyCompletionKey: String?
    public var dailyStreak: Int
    public var reminder: Reminder?
    public var createdAt: Date
    public var modifiedAt: Date
    public var deletedAt: Date?
    public var revision: Int64
    public var deviceID: String

    public init(
        id: LineID, cardID: CardID, kind: LineKind, text: String, sortIndex: Int64,
        isCompleted: Bool, completedAt: Date?, lastDailyCompletionKey: String?,
        dailyStreak: Int, reminder: Reminder?, createdAt: Date, modifiedAt: Date,
        deletedAt: Date?, revision: Int64, deviceID: String
    ) {
        self.id = id
        self.cardID = cardID
        self.kind = kind
        self.text = text
        self.sortIndex = sortIndex
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.lastDailyCompletionKey = lastDailyCompletionKey
        self.dailyStreak = dailyStreak
        self.reminder = reminder
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.revision = revision
        self.deviceID = deviceID
    }
}

public struct NewLineDraft: Codable, Sendable, Equatable {
    public let cardID: CardID
    public var kind: LineKind
    public var text: String
    public var isCompleted: Bool
    public var reminder: Reminder?

    public init(cardID: CardID, kind: LineKind, text: String, isCompleted: Bool = false, reminder: Reminder? = nil) {
        self.cardID = cardID
        self.kind = kind
        self.text = text
        self.isCompleted = isCompleted
        self.reminder = reminder
    }
}

public struct LineMutation: Codable, Sendable, Equatable {
    public let id: LineID
    public var kind: LineKind
    public var text: String
    public var reminder: Reminder?

    public init(id: LineID, kind: LineKind, text: String, reminder: Reminder?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.reminder = reminder
    }
}

public enum MoveDirection: String, Codable, Sendable {
    case up
    case down
}
