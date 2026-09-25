import Foundation

/// Structural validity, independent of LWW ordering and Inbox selection.
public enum DomainStructure {
    public static let reservedRecordIDs: Set<UUID> = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ]
    public static func validate(_ card: Card) throws {
        guard !reservedRecordIDs.contains(card.id.rawValue) else { throw StructuralIssue.identity }
        guard card.revision >= 0 && card.revision < Int64.max else { throw StructuralIssue.ordering }
        guard (!card.isInbox || card.status == .active),
              (card.status != .active || card.archivedAt == nil),
              (card.status == .trashed) == (card.deletedAt != nil) else {
            throw StructuralIssue.cardLifecycle
        }
        try validateDates([card.createdAt, card.modifiedAt, card.archivedAt, card.deletedAt])
    }
    public static func validate(_ line: CardLine, existingCardID: CardID? = nil) throws {
        guard !reservedRecordIDs.contains(line.id.rawValue), !reservedRecordIDs.contains(line.cardID.rawValue),
              line.id.rawValue != line.cardID.rawValue else {
            throw StructuralIssue.identity
        }
        guard line.sortIndex >= 0 && line.sortIndex < Int64.max,
              line.revision >= 0 && line.revision < Int64.max else { throw StructuralIssue.ordering }
        guard existingCardID == nil || existingCardID == line.cardID else { throw StructuralIssue.lineParent }
        guard line.dailyStreak >= 0,
              line.kind == .todo || (!line.isCompleted && line.reminder == nil) else { throw StructuralIssue.lineShape }
        do { try line.reminder?.validate() } catch { throw StructuralIssue.reminder }
        if case .daily(_, let zone) = line.reminder?.rule, TimeZone(identifier: zone) == nil { throw StructuralIssue.reminder }
        try validateDates([line.createdAt, line.modifiedAt, line.completedAt, line.deletedAt, line.reminder?.lastDeliveredAt])
    }
    public static func validateDates(_ dates: [Date?]) throws {
        // Codable Date can decode finite numbers far outside Calendar's domain.
        // Bound audit dates to Gregorian years 1...9999 before any projection.
        guard dates.compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSince1970.isFinite && (-62_135_596_800...253_402_300_799).contains($0.timeIntervalSince1970)
        }) else { throw StructuralIssue.timestamp }
    }
}

public enum StructuralIssue: String, Error, Codable, Sendable {
    case identity, ordering
    case cardLifecycle
    case lineShape, lineParent, reminder
    case undecodableRecord
    case timestamp
}
