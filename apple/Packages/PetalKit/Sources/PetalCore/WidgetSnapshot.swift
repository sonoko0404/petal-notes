import Foundation

public enum WidgetCardState: String, Codable, Sendable, Equatable {
    case normal, empty, archived, trashed, unavailable, persistenceError
}

public enum WidgetSyncBadge: String, Codable, Sendable, Equatable {
    case syncing, offline, failed
}

public struct WidgetLine: Identifiable, Codable, Sendable, Equatable {
    public let id: LineID
    public let kind: LineKind
    public let text: String
    public let isCompleted: Bool

    public init(id: LineID, kind: LineKind, text: String, isCompleted: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isCompleted = isCompleted
    }
}

/// Immutable presentation data. No repository, model context, or SDK UI types cross this boundary.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public let cardID: CardID
    public let title: String
    public let visibleLines: [WidgetLine]
    public let hiddenCount: Int
    public let cardState: WidgetCardState
    public let syncBadge: WidgetSyncBadge?
    public let nextRefresh: Date

    public init(cardID: CardID, title: String, visibleLines: [WidgetLine], hiddenCount: Int,
                cardState: WidgetCardState, syncBadge: WidgetSyncBadge? = nil, nextRefresh: Date) {
        self.cardID = cardID
        self.title = title
        self.visibleLines = visibleLines
        self.hiddenCount = hiddenCount
        self.cardState = cardState
        self.syncBadge = syncBadge
        self.nextRefresh = nextRefresh
    }
}
