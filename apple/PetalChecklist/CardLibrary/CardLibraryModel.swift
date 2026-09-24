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

    init(repository: any PetalRepository) { self.repository = repository }

    func show(_ scope: LibraryScope) async throws {
        self.scope = scope
        query = ""
        searchResults = []
        let all: [Card]
        switch scope {
        case .inbox, .allCards: all = try await repository.cards(scope: .active)
        case .archive: all = try await repository.cards(scope: .archived)
        case .trash: all = try await repository.cards(scope: .trashed)
        case .settings: all = []
        }
        cards = scope == .inbox ? all.filter(\.isInbox) : all
    }

    func search(_ text: String) async throws {
        query = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            try await show(scope)
            return
        }
        let matches = try await repository.search(text)
        let sourceCards = Dictionary(uniqueKeysWithValues: try await repository.cards(scope: .all).map { ($0.id, $0) })
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
    }

    @discardableResult
    func createCard(title: String) async throws -> Card {
        let card = try await repository.createCard(title: title, now: .now)
        try await show(.allCards)
        return card
    }

    func move(_ id: CardID, to status: CardStatus) async throws {
        let current = try await repository.card(id: id)
        var replacement: CardID?
        if current?.isInbox == true && status != .active {
            replacement = try await repository.cards(scope: .active).first(where: { $0.id != id })?.id
            if replacement == nil {
                replacement = try await repository.createCard(title: String(localized: "Inbox"), now: .now).id
            }
        }
        try await repository.moveCard(id, to: status, replacementInbox: replacement, now: .now)
        try await show(scope)
    }

    func restore(_ id: CardID) async throws {
        try await move(id, to: .active)
    }
}
