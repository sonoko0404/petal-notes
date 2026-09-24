import Foundation

/// Structural validity, independent of LWW ordering and Inbox selection.
public enum DomainStructure {
    public static func validate(_ card: Card) throws {
        guard (!card.isInbox || card.status == .active),
              (card.status != .active || card.archivedAt == nil),
              (card.status == .trashed) == (card.deletedAt != nil) else {
            throw StructuralIssue.cardLifecycle
        }
        try validateDates([card.createdAt, card.modifiedAt, card.archivedAt, card.deletedAt])
    }
    public static func validate(_ line: CardLine, existingCardID: CardID? = nil) throws {
        guard existingCardID == nil || existingCardID == line.cardID else { throw StructuralIssue.lineParent }
        guard line.dailyStreak >= 0,
              line.kind == .todo || (!line.isCompleted && line.reminder == nil) else { throw StructuralIssue.lineShape }
        do { try line.reminder?.validate() } catch { throw StructuralIssue.reminder }
        if case .daily(_, let zone) = line.reminder?.rule, TimeZone(identifier: zone) == nil { throw StructuralIssue.reminder }
        try validateDates([line.createdAt, line.modifiedAt, line.completedAt, line.deletedAt, line.reminder?.lastDeliveredAt])
    }
    public static func validateDates(_ dates: [Date?]) throws {
        guard dates.compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw StructuralIssue.timestamp }
    }
}

public enum StructuralIssue: String, Error, Codable, Sendable {
    case cardLifecycle
    case lineShape, lineParent, reminder
    case undecodableRecord
    case timestamp
}
