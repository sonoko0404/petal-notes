import Foundation

public struct Card: Identifiable, Codable, Sendable, Equatable {
    public let id: CardID
    public var title: String
    public var status: CardStatus
    public var themeID: ThemeID
    public var isInbox: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var archivedAt: Date?
    public var deletedAt: Date?
    public var revision: Int64
    public var deviceID: String

    public init(
        id: CardID, title: String, status: CardStatus, themeID: ThemeID,
        isInbox: Bool, createdAt: Date, modifiedAt: Date,
        archivedAt: Date?, deletedAt: Date?, revision: Int64, deviceID: String
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.themeID = themeID
        self.isInbox = isInbox
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.revision = revision
        self.deviceID = deviceID
    }
}

public enum CardScope: String, Codable, Sendable {
    case active
    case archived
    case trashed
    case all
}

public struct SearchResult: Codable, Sendable, Equatable {
    public let cardID: CardID
    public let lineID: LineID?
    public let title: String
    public let snippet: String

    public init(cardID: CardID, lineID: LineID?, title: String, snippet: String) {
        self.cardID = cardID
        self.lineID = lineID
        self.title = title
        self.snippet = snippet
    }
}
