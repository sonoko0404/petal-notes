import Foundation
import PetalCore
import PetalPersistence

/// Test-only fixtures backed by the production repository and a real in-memory SwiftData store.
public enum InMemoryPetalRepository {
    public struct Fixture: Sendable {
        public let repository: SwiftDataPetalRepository
        public let fixtureCardID: CardID
    }

    public static func bootstrapped(now: Date = DeterministicClock.referenceDate) async throws -> SwiftDataPetalRepository {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await repository.bootstrap(now: now)
        return repository
    }

    public static func cardWithTodos(count: Int, now: Date = DeterministicClock.referenceDate) async throws -> Fixture {
        let repository = try await bootstrapped(now: now)
        let card = try await repository.createCard(title: "Fixture", now: now)
        for index in 0..<max(0, count) {
            _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Todo \(index + 1)"), now: now)
        }
        return Fixture(repository: repository, fixtureCardID: card.id)
    }
}

public struct DeterministicClock: Sendable {
    public static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    public private(set) var now: Date
    public init(now: Date = Self.referenceDate) { self.now = now }
    public mutating func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}
