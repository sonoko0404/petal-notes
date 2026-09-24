import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

struct WidgetReadServiceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func suggestionsExcludeInactiveButIdentifierResolutionRetainsEverySelection() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped(now: now)
        let active = try await repository.createCard(title: "Active", now: now)
        let archived = try await repository.createCard(title: "Archived", now: now)
        let trashed = try await repository.createCard(title: "Trashed", now: now)
        let missing = CardID(rawValue: UUID())
        try await repository.moveCard(archived.id, to: .archived, replacementInbox: nil, now: now)
        try await repository.moveCard(trashed.id, to: .trashed, replacementInbox: nil, now: now)
        let query = WidgetCardQuery(repository: repository)
        let suggestions = try await query.suggestions()
        #expect(suggestions.contains { $0.id == active.id })
        #expect(!suggestions.contains { $0.id == archived.id || $0.id == trashed.id })
        let values = try await query.resolve(ids: [archived.id, missing, trashed.id])
        #expect(values.map(\.id) == [archived.id, missing, trashed.id])
        #expect(values.map(\.title) == ["Archived", nil, "Trashed"])
    }

    @Test func appGroupFailureIsExplicitAndHasDeterministicMidnightRetry() async {
        let reader = WidgetSnapshotReader {
            SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "missing", containerURL: { _ in nil }))
        }
        let id = CardID(rawValue: UUID())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = await reader.snapshot(cardID: id, size: .medium, now: now, calendar: calendar)
        #expect(snapshot.cardID == id)
        #expect(snapshot.cardState == .persistenceError)
        #expect(snapshot.visibleLines.isEmpty)
        #expect(snapshot.nextRefresh == Date(timeIntervalSince1970: 1_800_057_600))
    }

    @Test func failedReadUsesOnlySameCardSameSizeUnexpiredCache() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 8, now: now)
        let source = FailingAfterFirstOpen(repository: fixture.repository)
        let reader = WidgetSnapshotReader { try await source.open() }
        let calendar = Calendar(identifier: .gregorian)
        let first = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        let failed = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(failed.cardState == .persistenceError)
        #expect(failed.visibleLines == first.visibleLines)
        #expect(failed.hiddenCount == 3)
        let otherSize = await reader.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
        #expect(otherSize.visibleLines.isEmpty)
        let otherCard = await reader.snapshot(cardID: CardID(rawValue: UUID()), size: .medium, now: now, calendar: calendar)
        #expect(otherCard.visibleLines.isEmpty)
        let expired = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: first.nextRefresh, calendar: calendar)
        #expect(expired.visibleLines.isEmpty)
    }

    @Test func failedReadDoesNotReuseCacheFromAnotherLocalDayBoundary() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let line = try #require(await fixture.repository.lines(cardID: fixture.fixtureCardID).first)
        try await fixture.repository.setCompleted(lineID: line.id, completed: true, now: now.addingTimeInterval(-3600))
        let source = FailingAfterFirstOpen(repository: fixture.repository)
        let reader = WidgetSnapshotReader { try await source.open() }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: utc)
        #expect(first.visibleLines.count == 1)
        var losAngeles = utc
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 08:00 UTC is midnight in LA; this completion was yesterday there.
        let failed = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: losAngeles)
        #expect(failed.cardState == .persistenceError)
        #expect(failed.visibleLines.isEmpty)
    }
}

private actor FailingAfterFirstOpen {
    let repository: any PetalRepository
    var opened = false
    init(repository: any PetalRepository) { self.repository = repository }
    func open() throws -> any PetalRepository {
        guard !opened else { throw RepositoryError.appGroupUnavailable }
        opened = true
        return repository
    }
}
