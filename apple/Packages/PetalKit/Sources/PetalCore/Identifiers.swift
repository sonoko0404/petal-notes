import Foundation

public struct CardID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct LineID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum CardStatus: String, Codable, Sendable {
    case active
    case archived
    case trashed
}

public enum LineKind: String, Codable, Sendable {
    case text
    case todo
}

public enum ThemeID: String, Codable, CaseIterable, Sendable {
    case cream
    case mint
    case sakura
    case sky
    case paper
}

public enum WidgetDisplaySize: String, Codable, Sendable {
    case medium
    case large
}
