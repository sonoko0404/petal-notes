import Foundation
import PetalCore

public extension Notification.Name {
    static let petalRepositoryDidCommit = Notification.Name("petal.repository.didCommit")
}

public protocol PetalRepository: Sendable {
    func bootstrap(now: Date) async throws
    func cards(scope: CardScope) async throws -> [Card]
    func card(id: CardID) async throws -> Card?
    func lines(cardID: CardID) async throws -> [CardLine]
    func addLine(_ draft: NewLineDraft, now: Date) async throws -> CardLine
    func captureTodoLines(cardID: CardID, texts: [String], now: Date) async throws -> [CardLine]
    func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine
    func deleteLine(lineID: LineID, now: Date) async throws
    func setReminder(lineID: LineID, reminder: Reminder?, now: Date) async throws -> CardLine
    func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws
    func setWidgetCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws
    func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) async throws
    func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws
    func moveCardEnsuringInbox(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws
    func search(_ query: String) async throws -> [SearchResult]
    func purgeExpiredTrash(now: Date) async throws
    func captureConflict(cardID: CardID, lineID: LineID?, losingPayload: Data, now: Date) async throws -> ConflictArtifact
    func conflicts() async throws -> [ConflictArtifact]
    func recoverConflict(id: UUID, now: Date) async throws -> CardID
    func purgeExpiredConflicts(now: Date) async throws
    func deleteAllData(resetGeneration: UUID, now: Date) async throws
    func resetGeneration() async throws -> UUID?
    func createCard(title: String, now: Date) async throws -> Card
    func updateCardTitle(_ id: CardID, title: String, now: Date) async throws -> Card
    func pendingOutboxCount() async throws -> Int
    func pendingOutbox() async throws -> [OutboxChange]
}
