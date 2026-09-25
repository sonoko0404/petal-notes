import Foundation
import SwiftData
import Testing
import PetalCore
@testable import PetalPersistence

private let mutationNow = Date(timeIntervalSince1970: 1_800_000_000)
private var mutationCalendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = .gmt; return value
}

@MainActor @Test(.serialized, arguments: [false, true])
func finalSharedCommitPublishesContentFreeCrossProcessInvalidation(inbound: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    let signal = CommitSignal()
    let observer = DistributedNotificationCenter.default().addObserver(forName: .petalRepositoryDidCommit,
        object: String(ProcessInfo.processInfo.processIdentifier), queue: .main) { note in
            if note.userInfo == nil { signal.receive() }
        }
    defer { DistributedNotificationCenter.default().removeObserver(observer) }
    if inbound {
        let card = Card(id: CardID(rawValue: UUID()), title: "Never carried in signal", status: .active,
            themeID: .cream, isInbox: true, createdAt: mutationNow, modifiedAt: mutationNow,
            archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "remote")
        try await repository.applyInbound([ReplicatedRecord(payload: .card(card), generation: .initial)], token: nil, now: mutationNow)
    } else {
        _ = try await repository.createCard(title: "Never carried in signal", now: mutationNow)
    }
    for _ in 0..<50 where !signal.received { try await Task.sleep(for: .milliseconds(10)) }
    #expect(signal.received)
}

private final class CommitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var received: Bool { lock.withLock { value } }
    func receive() { lock.withLock { value = true } }
}

@Test func finalDailyCompletionUpdatesDateAndStreakWithIdempotenceMissedDayAndUndo() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Daily", now: mutationNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Daily",
        reminder: Reminder(rule: .daily(localMinute: 600, timeZoneIdentifier: "UTC"), isEnabled: true)), now: mutationNow)
    try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow, calendar: mutationCalendar)
    let first = try #require(await repository.lines(cardID: card.id).first)
    #expect(first.lastDailyCompletionKey == "2027-01-15")
    #expect(first.dailyStreak == 1)
    try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow.addingTimeInterval(60), calendar: mutationCalendar)
    #expect(try await repository.lines(cardID: card.id).first?.revision == first.revision)
    try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow.addingTimeInterval(86_400), calendar: mutationCalendar)
    #expect(try await repository.lines(cardID: card.id).first?.dailyStreak == 2)
    try await repository.setWidgetCompleted(lineID: line.id, completed: false, now: mutationNow.addingTimeInterval(86_400), calendar: mutationCalendar)
    let undone = try #require(await repository.lines(cardID: card.id).first)
    #expect(undone.lastDailyCompletionKey == "2027-01-15")
    #expect(undone.dailyStreak == 1)
    try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow.addingTimeInterval(86_400), calendar: mutationCalendar)
    #expect(try await repository.lines(cardID: card.id).first?.dailyStreak == 2)
    try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow.addingTimeInterval(3 * 86_400), calendar: mutationCalendar)
    #expect(try await repository.lines(cardID: card.id).first?.dailyStreak == 1)
    #expect(try await repository.lines(cardID: card.id).first?.lastDailyCompletionKey == "2027-01-18")
}

@Test func finalDailyOrdinaryCompletionCanCompleteAgainTomorrow() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Daily", now: mutationNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Daily",
        reminder: Reminder(rule: .daily(localMinute: 600, timeZoneIdentifier: "UTC"), isEnabled: true)), now: mutationNow)
    try await repository.setCompleted(lineID: line.id, completed: true, now: mutationNow)
    try await repository.setCompleted(lineID: line.id, completed: true, now: mutationNow.addingTimeInterval(86_400))
    #expect(try await repository.lines(cardID: card.id).first?.completedAt == mutationNow.addingTimeInterval(86_400))
    #expect(try await repository.lines(cardID: card.id).first?.dailyStreak == 2)
}

@Test func finalExtremeExistingOrderingReindexesBeforeAtomicMultilineInsertion() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    let card = try await repository.createCard(title: "Order", now: mutationNow)
    var line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Existing"), now: mutationNow)
    line.sortIndex = Int64.max - 3
    try await repository.replaceUserData(TransferSnapshot(cards: [card], lines: [line]), now: mutationNow)
    // Imported values near the limit are reindexed with room for future edits.
    let inserted = try await repository.captureTodoLines(cardID: card.id, texts: ["Second", "Third"], now: mutationNow)
    #expect(inserted.map(\.sortIndex) == [1, 2])
    #expect(try await repository.lines(cardID: card.id).map(\.sortIndex) == [0, 1, 2])
    #expect(try await repository.lines(cardID: card.id).map(\.text) == ["Existing", "Second", "Third"])
}

@Test func finalLineDeletionIsAtomicContentFreeAndRejectsStaleIntents() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    let card = try await repository.createCard(title: "Keep card", now: mutationNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Erase me"), now: mutationNow)
    let before = try await repository.pendingOutbox()
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) { try await failing.deleteLine(lineID: line.id, now: mutationNow) }
    #expect(try await repository.lines(cardID: card.id) == [line])
    #expect(try await repository.pendingOutbox() == before)
    try await repository.deleteLine(lineID: line.id, now: mutationNow)
    #expect(try await repository.lines(cardID: card.id).isEmpty)
    #expect(try await repository.card(id: card.id) != nil)
    let changes = try await repository.pendingOutbox().filter { $0.entityID == line.id.rawValue }
    #expect(changes.count == 1)
    #expect(changes.first?.operation == .delete)
    #expect(changes.first?.payload.isEmpty == true)
    #expect(try await repository.syncSnapshot().tombstones.contains { $0.entityID == line.id.rawValue })
    await #expect(throws: RepositoryError.lineUnavailable) {
        try await repository.setWidgetCompleted(lineID: line.id, completed: true, now: mutationNow, calendar: mutationCalendar)
    }
}

@Test func finalConflictRecoverySurvivesNoticeDismissalRelaunchAndIsIdempotentUntilExpiry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open()
    let card = try await repository.createCard(title: "Source", now: mutationNow)
    let line = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Losing draft"), now: mutationNow)
    let conflict = try await repository.captureConflict(cardID: card.id, lineID: line.id,
        losingPayload: JSONEncoder().encode(line), now: mutationNow)
    #expect(try await repository.takeUnpresentedConflicts(now: mutationNow).count == 1)
    let reopened = try open()
    #expect(try await reopened.takeUnpresentedConflicts(now: mutationNow).isEmpty)
    #expect(try await reopened.conflicts().count == 1)
    let recovered = try await reopened.recoverConflict(id: conflict.id, now: mutationNow)
    #expect(try await reopened.lines(cardID: recovered).map(\.text) == ["Losing draft"])
    #expect(try await reopened.lines(cardID: card.id) == [line])
    #expect(try await open().recoverConflict(id: conflict.id, now: mutationNow) == recovered)
    #expect(try await reopened.conflicts().first?.losingPayload == conflict.losingPayload)
    try await reopened.purgeExpiredConflicts(now: mutationNow.addingTimeInterval(2_592_001))
    #expect(try await reopened.conflicts().isEmpty)
    #expect(try await reopened.lines(cardID: recovered).count == 1)
    await #expect(throws: (any Error).self) { try await reopened.recoverConflict(id: conflict.id, now: mutationNow) }
}
