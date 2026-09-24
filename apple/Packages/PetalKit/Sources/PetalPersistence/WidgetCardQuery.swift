import PetalCore

public struct WidgetCardChoice: Sendable, Equatable {
    public let id: CardID
    /// Nil denotes a deleted or otherwise unavailable configured card.
    public let title: String?
}

public struct WidgetCardQuery: Sendable {
    private let repository: any PetalRepository
    public init(repository: any PetalRepository) { self.repository = repository }

    public func suggestions() async throws -> [WidgetCardChoice] {
        try await repository.cards(scope: .active).map { WidgetCardChoice(id: $0.id, title: $0.title) }
    }

    /// Identifier restoration is deliberately broader than the active-card picker.
    public func resolve(ids: [CardID]) async throws -> [WidgetCardChoice] {
        var values: [WidgetCardChoice] = []
        for id in ids {
            let card = try await repository.card(id: id)
            values.append(WidgetCardChoice(id: id, title: card?.title))
        }
        return values
    }
}
