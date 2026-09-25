import Foundation
import PetalCore

public struct TransferSnapshot: Sendable, Equatable {
    public var cards: [Card]
    public var lines: [CardLine]
    public init(cards: [Card], lines: [CardLine]) { self.cards = cards; self.lines = lines }
    public func validate() throws {
        let ids = Set(cards.map(\.id))
        let allIDs = cards.map { $0.id.rawValue } + lines.map { $0.id.rawValue }
        guard ids.count == cards.count, Set(lines.map(\.id)).count == lines.count,
              Set(allIDs).count == allIDs.count,
              cards.filter(\.isInbox).count <= 1,
              lines.allSatisfy({ ids.contains($0.cardID) }) else {
            throw TransferRepositoryError.invalidSnapshot
        }
        for card in cards { try DomainStructure.validate(card) }
        for line in lines { try DomainStructure.validate(line) }
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
