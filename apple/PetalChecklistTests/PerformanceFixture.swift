import Foundation
import PetalCore
import PetalPersistence

/// Synthetic fixture shared by hosted and UI performance tests. Not linked to shipped products.
enum PerformanceFixture {
    @MainActor static func make(root: URL) async throws -> (SwiftDataPetalRepository, TransferSnapshot) {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "performance.fixture", containerURL: { _ in root }))
        let now = Date.now
        var cards: [Card] = []
        var rows: [CardLine] = []
        for index in 0..<500 {
            let id = CardID(rawValue: UUID())
            cards.append(Card(id: id, title: "Card \(index)", status: .active, themeID: .cream, isInbox: index == 0,
                createdAt: now, modifiedAt: now, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "fixture"))
            for offset in 0..<10 {
                rows.append(CardLine(id: LineID(rawValue: UUID()), cardID: id, kind: .todo,
                    text: offset == 9 ? "needle \(index)" : "Todo \(offset)", sortIndex: Int64(offset),
                    isCompleted: false, completedAt: nil, lastDailyCompletionKey: nil, dailyStreak: 0, reminder: nil,
                    createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: "fixture"))
            }
        }
        try await repository.replaceUserData(TransferSnapshot(cards: cards, lines: rows), now: now)
        try await repository.setSyncEnabled(false)
        let snapshot = try await repository.transferSnapshot()
        return (repository, snapshot)
    }
}
