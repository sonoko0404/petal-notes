import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

struct ReminderMutationTests {
    @Test func invalidRulesRejectAtReminderBoundary() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        for rule in [ReminderRule.daily(localMinute: -1, timeZoneIdentifier: "UTC"), .oneTime(Date(timeIntervalSince1970: .infinity))] {
            await #expect(throws: ReminderValidationError.invalidRule) {
                _ = try await f.repository.setReminder(lineID: line.id, reminder: Reminder(rule: rule, isEnabled: true), now: .now)
            }
        }
    }
    @Test func reminderOnlyMutationIsAtomicAndRejectsText() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let repo = SwiftDataPetalRepository(container: store)
        let card = try await repo.createCard(title: "A", now: .now)
        let todo = try await repo.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Keep"), now: .now)
        let text = try await repo.addLine(NewLineDraft(cardID: card.id, kind: .text, text: "Note"), now: .now)
        let reminder = Reminder(rule: .oneTime(Date(timeIntervalSince1970: 2_000_000_000)), isEnabled: true)
        let count = try await repo.pendingOutboxCount()
        let failing = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
        await #expect(throws: RepositoryError.injectedFailure) { _ = try await failing.setReminder(lineID: todo.id, reminder: reminder, now: .now) }
        #expect(try await repo.lines(cardID: card.id).first == todo)
        #expect(try await repo.pendingOutboxCount() == count)
        await #expect(throws: RepositoryError.lineUnavailable) { _ = try await repo.setReminder(lineID: text.id, reminder: reminder, now: .now) }
        let saved = try await repo.setReminder(lineID: todo.id, reminder: reminder, now: .now)
        #expect(saved.text == "Keep")
        #expect(saved.reminder == reminder)
        #expect(saved.revision == todo.revision + 1)
        #expect(try await repo.pendingOutboxCount() == count + 1)
    }
    @Test func invalidDailyMinuteDoesNotCommit() async throws {
        let f = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let line = try #require(await f.repository.lines(cardID: f.fixtureCardID).first)
        let count = try await f.repository.pendingOutboxCount()
        await #expect(throws: (any Error).self) {
            _ = try await f.repository.updateLine(LineMutation(id: line.id, kind: .todo, text: line.text,
                reminder: Reminder(rule: .daily(localMinute: 1440, timeZoneIdentifier: "UTC"), isEnabled: true)), now: .now)
        }
        #expect(try await f.repository.pendingOutboxCount() == count)
        #expect(try await f.repository.lines(cardID: f.fixtureCardID).first == line)
    }
}
