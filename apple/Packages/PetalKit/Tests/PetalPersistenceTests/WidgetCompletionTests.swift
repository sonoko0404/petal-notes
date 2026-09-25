import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

struct WidgetCompletionTests {
    @Test func inactiveAndTextLinesCannotBeChanged() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        try await f.repository.moveCard(f.fixtureCardID, to: .archived, replacementInbox: nil, now: .now)
        let before = try await f.repository.pendingOutboxCount()
        await #expect(throws: RepositoryError.cardUnavailable) {
            try await f.repository.setWidgetCompleted(lineID: line.id, completed: true, now: .now, calendar: .current)
        }
        #expect(try await f.repository.pendingOutboxCount() == before)
        try await f.repository.moveCard(f.fixtureCardID, to: .active, replacementInbox: nil, now: .now)
        let text = try await f.repository.addLine(NewLineDraft(cardID: f.fixtureCardID, kind: .text, text: "Text"), now: .now)
        await #expect(throws: RepositoryError.lineUnavailable) {
            try await f.repository.setWidgetCompleted(lineID: text.id, completed: true, now: .now, calendar: .current)
        }
    }

    @Test func dailyCompletionAfterMidnightUsesCurrentDayAndDuplicatesDoNotWrite() async throws {
        let now = DeterministicClock.referenceDate
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 0, now: now)
        let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
        let line = try await f.repository.addLine(NewLineDraft(cardID: f.fixtureCardID, kind: .todo,
            text: "Daily", isCompleted: true,
            reminder: Reminder(rule: .daily(localMinute: 540, timeZoneIdentifier: "UTC"), isEnabled: true)), now: now)
        let tomorrow = now.addingTimeInterval(86400)
        try await f.repository.setWidgetCompleted(lineID: line.id, completed: true, now: tomorrow, calendar: calendar)
        let first = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        #expect(first.completedAt == tomorrow)
        let count = try await f.repository.pendingOutboxCount()
        async let a: Void = f.repository.setWidgetCompleted(lineID: line.id, completed: true, now: tomorrow.addingTimeInterval(5), calendar: calendar)
        async let b: Void = f.repository.setWidgetCompleted(lineID: line.id, completed: true, now: tomorrow.addingTimeInterval(6), calendar: calendar)
        _ = try await (a, b)
        #expect(try await f.repository.pendingOutboxCount() == count)
        #expect(try await f.repository.lines(cardID: f.fixtureCardID).first == first)
    }

    @Test func missingLineIsNeverRecreated() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let before = try await repository.pendingOutboxCount()
        await #expect(throws: RepositoryError.lineUnavailable) {
            try await repository.setWidgetCompleted(lineID: LineID(rawValue: UUID()), completed: true,
                now: .now, calendar: .current)
        }
        #expect(try await repository.pendingOutboxCount() == before)
    }
}
