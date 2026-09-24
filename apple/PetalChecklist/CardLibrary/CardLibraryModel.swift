import Foundation
import Observation
import PetalCore
import PetalPersistence

struct LibrarySearchResult: Identifiable {
    let result: SearchResult
    let scope: LibraryScope
    var id: String { "\(result.cardID.rawValue)-\(result.lineID?.rawValue.uuidString ?? "title")" }
}

@MainActor @Observable
final class CardLibraryModel {
    private let repository: any PetalRepository
    private(set) var scope: LibraryScope = .inbox
    private(set) var cards: [Card] = []
    private(set) var searchResults: [LibrarySearchResult] = []
    private(set) var query = ""
    var errorMessage: String?
    @ObservationIgnored private var searchGeneration = 0

    init(repository: any PetalRepository) { self.repository = repository }

    func show(_ scope: LibraryScope) async throws {
        self.scope = scope
        try await refresh()
    }

    func refresh() async throws {
        searchGeneration += 1
        let generation = searchGeneration
        do { try await load(query, generation: generation) }
        catch {
            if generation == searchGeneration { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private func load(_ text: String, generation: Int) async throws {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let matches = try await repository.search(text)
            let sourceCards = Dictionary(uniqueKeysWithValues: try await repository.cards(scope: .all).map { ($0.id, $0) })
            guard generation == searchGeneration, query == text else { return }
            searchResults = matches.compactMap { match in
                guard let card = sourceCards[match.cardID] else { return nil }
                let source: LibraryScope
                switch card.status {
                case .active: source = card.isInbox ? .inbox : .allCards
                case .archived: source = .archive
                case .trashed: source = .trash
                }
                return LibrarySearchResult(result: match, scope: source)
            }
            errorMessage = nil
            return
        }
        let all: [Card]
        switch scope {
        case .inbox, .allCards: all = try await repository.cards(scope: .active)
        case .archive: all = try await repository.cards(scope: .archived)
        case .trash: all = try await repository.cards(scope: .trashed)
        case .settings: all = []
        }
        guard generation == searchGeneration, query == text else { return }
        cards = scope == .inbox ? all.filter(\.isInbox) : all
        searchResults = []
        errorMessage = nil
    }

    func search(_ text: String) async throws {
        query = text
        searchGeneration += 1
        let generation = searchGeneration
        do { try await load(text, generation: generation) }
        catch {
            if generation == searchGeneration { errorMessage = error.localizedDescription }
            throw error
        }
    }

    func setQuery(_ text: String) {
        query = text
        searchGeneration += 1
        let generation = searchGeneration
        Task {
            do { try await load(text, generation: generation) }
            catch {
                if generation == searchGeneration { errorMessage = error.localizedDescription }
            }
        }
    }

    func retryQuery() async {
        do { try await refresh() } catch { }
    }

    @discardableResult
    func createCard(title: String) async throws -> Card {
        let card = try await repository.createCard(title: title, now: .now)
        scope = .allCards
        do { try await refresh() } catch { /* the card is committed; Retry refreshes the view */ }
        return card
    }

    func replacementCandidates(for id: CardID) async throws -> [Card] {
        guard try await repository.card(id: id)?.isInbox == true else { return [] }
        return try await repository.cards(scope: .active).filter { $0.id != id }
    }

    func move(_ id: CardID, to status: CardStatus, replacementInbox: CardID? = nil) async throws {
        try await repository.moveCardEnsuringInbox(id, to: status, replacementInbox: replacementInbox, now: .now)
        do { try await refresh() } catch { /* the move is committed; Retry refreshes the view */ }
    }

    func restore(_ id: CardID) async throws {
        try await move(id, to: .active)
    }
}
