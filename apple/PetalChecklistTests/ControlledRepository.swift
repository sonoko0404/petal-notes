import Foundation
import PetalCore
import PetalPersistence

@MainActor
final class RepositoryGate {
    var suspended = false
    private var entered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func pauseNext() { suspended = true; entered = false }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiter = $0 }
    }

    func enter() async {
        guard suspended else { return }
        suspended = false
        entered = true
        enterWaiter?.resume()
        enterWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

@MainActor
final class ControlledRepository: PetalRepository {
    let base: any PetalRepository
    let titleGate = RepositoryGate()
    let addGate = RepositoryGate()
    let captureGate = RepositoryGate()
    let searchGate = RepositoryGate()
    let cardGate = RepositoryGate()
    let linesGate = RepositoryGate()
    var failNextCard = false
    var failNextAdd = false
    var failNextCapture = false
    var archiveBeforeCapture = false
    var failNextSearch = false
    var failNextCards = false
    var failNextTitle = false

    init(base: any PetalRepository) { self.base = base }
    func bootstrap(now: Date) async throws { try await base.bootstrap(now: now) }
    func cards(scope: CardScope) async throws -> [Card] {
        if failNextCards { failNextCards = false; throw RepositoryError.injectedFailure }
        return try await base.cards(scope: scope)
    }
    func card(id: CardID) async throws -> Card? {
        await cardGate.enter()
        if failNextCard { failNextCard = false; throw RepositoryError.injectedFailure }
        return try await base.card(id: id)
    }
    func lines(cardID: CardID) async throws -> [CardLine] {
        let lines = try await base.lines(cardID: cardID)
        await linesGate.enter()
        return lines
    }
    func addLine(_ draft: NewLineDraft, now: Date) async throws -> CardLine {
        await addGate.enter()
        if failNextAdd { failNextAdd = false; throw RepositoryError.injectedFailure }
        return try await base.addLine(draft, now: now)
    }
    func captureTodoLines(cardID: CardID, texts: [String], now: Date) async throws -> [CardLine] {
        await captureGate.enter()
        if archiveBeforeCapture {
            archiveBeforeCapture = false
            try await base.moveCard(cardID, to: .archived, replacementInbox: nil, now: now)
        }
        if failNextCapture {
            failNextCapture = false
            throw RepositoryError.injectedFailure
        }
        return try await base.captureTodoLines(cardID: cardID, texts: texts, now: now)
    }
    func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine { try await base.updateLine(mutation, now: now) }
    func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws { try await base.setCompleted(lineID: lineID, completed: completed, now: now) }
    func setWidgetCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        try await base.setWidgetCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
    }
    func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) async throws { try await base.reorder(cardID: cardID, orderedLineIDs: orderedLineIDs, now: now) }
    func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws { try await base.moveCard(id, to: status, replacementInbox: replacementInbox, now: now) }
    func moveCardEnsuringInbox(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws { try await base.moveCardEnsuringInbox(id, to: status, replacementInbox: replacementInbox, now: now) }
    func search(_ query: String) async throws -> [SearchResult] {
        await searchGate.enter()
        if failNextSearch { failNextSearch = false; throw RepositoryError.injectedFailure }
        return try await base.search(query)
    }
    func purgeExpiredTrash(now: Date) async throws { try await base.purgeExpiredTrash(now: now) }
    func captureConflict(cardID: CardID, lineID: LineID?, losingPayload: Data, now: Date) async throws -> ConflictArtifact { try await base.captureConflict(cardID: cardID, lineID: lineID, losingPayload: losingPayload, now: now) }
    func conflicts() async throws -> [ConflictArtifact] { try await base.conflicts() }
    func purgeExpiredConflicts(now: Date) async throws { try await base.purgeExpiredConflicts(now: now) }
    func deleteAllData(resetGeneration: UUID, now: Date) async throws { try await base.deleteAllData(resetGeneration: resetGeneration, now: now) }
    func resetGeneration() async throws -> UUID? { try await base.resetGeneration() }
    func createCard(title: String, now: Date) async throws -> Card { try await base.createCard(title: title, now: now) }
    func updateCardTitle(_ id: CardID, title: String, now: Date) async throws -> Card {
        await titleGate.enter()
        if failNextTitle { failNextTitle = false; throw RepositoryError.injectedFailure }
        return try await base.updateCardTitle(id, title: title, now: now)
    }
    func pendingOutboxCount() async throws -> Int { try await base.pendingOutboxCount() }
    func pendingOutbox() async throws -> [OutboxChange] { try await base.pendingOutbox() }
}
