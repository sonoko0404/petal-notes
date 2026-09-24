import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

struct WidgetSnapshotBuilderTests {
    let now = ISO8601DateFormatter().date(from: "2026-09-23T19:00:00Z")!
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }

    @Test func capacitiesCountEveryOverflowRowInManualOrder() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 12, now: now)
        let builder = WidgetSnapshotBuilder(repository: fixture.repository)
        let medium = try await builder.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        let large = try await builder.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
        #expect(medium.visibleLines.map(\.text) == ["Todo 1", "Todo 2", "Todo 3", "Todo 4", "Todo 5"])
        #expect(medium.hiddenCount == 7)
        #expect(large.visibleLines.count == 10)
        #expect(large.visibleLines.last?.text == "Todo 10")
        #expect(large.hiddenCount == 2)
        #expect(medium.cardState == .normal)
    }

    @Test func displayPolicyKeepsTextAndIncompleteManualOrderThenTodaysCompletions() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 6, now: now)
        let repository = fixture.repository
        let rows = try await repository.lines(cardID: fixture.fixtureCardID)
        try await repository.setCompleted(lineID: rows[0].id, completed: true, now: now)
        try await repository.setCompleted(lineID: rows[1].id, completed: true, now: now.addingTimeInterval(-86400))
        _ = try await repository.addLine(.init(cardID: fixture.fixtureCardID, kind: .text, text: "A note"), now: now)
        try await repository.reorder(cardID: fixture.fixtureCardID,
            orderedLineIDs: Array(rows.reversed().map(\.id)) + [try await repository.lines(cardID: fixture.fixtureCardID).last!.id], now: now)
        let snapshot = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(snapshot.visibleLines.map(\.text) == ["Todo 6", "Todo 5", "Todo 4", "Todo 3", "A note"])
        #expect(snapshot.hiddenCount == 1)
        let large = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
        #expect(large.visibleLines.last?.text == "Todo 1")
        #expect(large.visibleLines.last?.isCompleted == true)
    }

    @Test func dailyTodoRestoresAtMidnightWithoutWritingStore() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped(now: now)
        let card = try await repository.createCard(title: "Daily", now: now)
        let line = try await repository.addLine(.init(cardID: card.id, kind: .todo, text: "Water plants",
            isCompleted: true, reminder: .init(rule: .daily(localMinute: 600, timeZoneIdentifier: "America/Los_Angeles"), isEnabled: true)), now: now)
        let before = try await repository.pendingOutboxCount()
        let snapshot = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: card.id, size: .medium,
            now: ISO8601DateFormatter().date(from: "2026-09-24T07:00:00Z")!, calendar: calendar)
        #expect(snapshot.visibleLines.map(\.id) == [line.id])
        #expect(snapshot.visibleLines.first?.isCompleted == false)
        #expect(try await repository.lines(cardID: card.id).first?.isCompleted == true)
        #expect(try await repository.pendingOutboxCount() == before)
    }

    @Test func cardLifecycleKeepsConfiguredIdentityAndHidesInactiveContents() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let builder = WidgetSnapshotBuilder(repository: fixture.repository)
        for (status, expected) in [(CardStatus.archived, WidgetCardState.archived), (.trashed, .trashed)] {
            try await fixture.repository.moveCard(fixture.fixtureCardID, to: status, replacementInbox: nil, now: now)
            let snapshot = try await builder.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
            #expect(snapshot.cardID == fixture.fixtureCardID)
            #expect(snapshot.cardState == expected)
            #expect(snapshot.visibleLines.isEmpty)
        }
        try await fixture.repository.purgeExpiredTrash(now: now.addingTimeInterval(30 * 86400))
        let missing = try await builder.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(missing.cardState == .unavailable)
        #expect(missing.cardID == fixture.fixtureCardID)
        let emptyCard = try await fixture.repository.createCard(title: "Empty", now: now)
        let empty = try await builder.snapshot(cardID: emptyCard.id, size: .medium, now: now, calendar: calendar)
        #expect(empty.cardState == .empty)
    }

    @Test(arguments: [
        ("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z"),
        ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z"),
        ("2026-09-24T06:59:59Z", "2026-09-24T07:00:00Z")
    ]) func refreshUsesNextLocalMidnightIncludingDST(input: (String, String)) async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let date = ISO8601DateFormatter()
        let snapshot = try await WidgetSnapshotBuilder(repository: fixture.repository).snapshot(cardID: fixture.fixtureCardID, size: .medium, now: date.date(from: input.0)!, calendar: calendar)
        #expect(snapshot.nextRefresh == date.date(from: input.1)!)
    }
}
