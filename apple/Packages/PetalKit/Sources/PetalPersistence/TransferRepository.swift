import Foundation
import PetalCore

public struct TransferSnapshot: Sendable, Equatable {
    public var cards: [Card]
    public var lines: [CardLine]
    public init(cards: [Card], lines: [CardLine]) { self.cards = cards; self.lines = lines }
    public func validate() throws {
        let ids = Set(cards.map(\.id))
        guard ids.count == cards.count, Set(lines.map(\.id)).count == lines.count,
              cards.filter(\.isInbox).count <= 1,
              cards.allSatisfy({ !$0.isInbox || $0.status == .active }),
              cards.allSatisfy({ ($0.status == .trashed) == ($0.deletedAt != nil) }),
              lines.allSatisfy({ ids.contains($0.cardID) && $0.dailyStreak >= 0
                && ($0.kind == .todo || (!$0.isCompleted && $0.reminder == nil)) }) else {
            throw TransferRepositoryError.invalidSnapshot
        }
        for line in lines {
            try line.reminder?.validate()
            if case .daily(_, let zone) = line.reminder?.rule, TimeZone(identifier: zone) == nil {
                throw TransferRepositoryError.invalidSnapshot
            }
        }
    }
}

public enum TransferRepositoryError: Error, Sendable { case invalidSnapshot }

public struct ImportedCard: Sendable {
    public let card: Card
    public let lines: [CardLine]
    public let fingerprint: String
    public let sourceNoteID: UUID
    public init(card: Card, lines: [CardLine], fingerprint: String, sourceNoteID: UUID) {
        self.card = card; self.lines = lines; self.fingerprint = fingerprint; self.sourceNoteID = sourceNoteID
    }
}

public protocol PetalTransferRepository: PetalRepository {
    func transferSnapshot() async throws -> TransferSnapshot
    func importCards(_ cards: [ImportedCard], now: Date,
        backup: @Sendable (TransferSnapshot) throws -> Void) async throws -> Int
    func replaceUserData(_ snapshot: TransferSnapshot, now: Date) async throws
}
