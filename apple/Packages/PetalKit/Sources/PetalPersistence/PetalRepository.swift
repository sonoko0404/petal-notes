import Foundation
import PetalCore

public protocol PetalRepository: Sendable {
    func bootstrap(now: Date) async throws
    func cards(scope: CardScope) async throws -> [Card]
    func card(id: CardID) async throws -> Card?
    func lines(cardID: CardID) async throws -> [CardLine]
    func addLine(_ draft: NewLineDraft, now: Date) async throws -> CardLine
    func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine
    func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws
    func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) async throws
    func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws
    func search(_ query: String) async throws -> [SearchResult]
    func purgeExpiredTrash(now: Date) async throws
    func captureConflict(cardID: CardID, lineID: LineID?, losingPayload: Data, now: Date) async throws -> ConflictArtifact
    func conflicts() async throws -> [ConflictArtifact]
    func purgeExpiredConflicts(now: Date) async throws
    func deleteAllData(resetGeneration: UUID, now: Date) async throws
    func resetGeneration() async throws -> UUID?
    func createCard(title: String, now: Date) async throws -> Card
    func updateCardTitle(_ id: CardID, title: String, now: Date) async throws -> Card
    func pendingOutboxCount() async throws -> Int
    func pendingOutbox() async throws -> [OutboxChange]
}
