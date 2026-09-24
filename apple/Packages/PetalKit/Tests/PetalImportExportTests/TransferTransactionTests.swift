import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalImportExport

@Test func importedBatchPersistsFingerprintAcrossRelaunchAndPartialOverlap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    try await repository.bootstrap(now: transferNow)
    #expect(try await repository.importCards(entries, now: transferNow, backup: { _ in }) == 1)
    let reopened = SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    #expect(try await reopened.importCards(entries, now: transferNow, backup: { _ in }) == 0)
    let newData = Data(String(decoding: try windowsFixture(), as: UTF8.self)
        .replacingOccurrences(of: "4dbfd594-1ee5-472b-8a00-687675b485f7", with: "b2ac1d12-bde1-42a6-aeaf-9e0b5c34fc3b")
        .replacingOccurrences(of: "Garden checklist", with: "New source").utf8)
    let other = try WindowsNotesImporter.decode(newData, now: transferNow, timeZone: .gmt)
    #expect(try await reopened.importCards(entries + other, now: transferNow, backup: { _ in }) == 1)
    #expect(try await reopened.cards(scope: .all).count == 3)
    #expect(try await reopened.cards(scope: .active).filter(\.isInbox).count == 1)
    #expect(try await reopened.pendingOutboxCount() == 11)
    let snapshot = try await reopened.transferSnapshot()
    #expect(snapshot.cards.count == 3)
    #expect(snapshot.lines.count == 8)
}

@Test func backupFailureAndTransactionFailureDoNotCommitCardsOutboxOrFingerprints() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    try await repository.bootstrap(now: transferNow)
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let before = try await repository.cards(scope: .all)
    let outbox = try await repository.pendingOutbox()
    await #expect(throws: CocoaError(.fileWriteNoPermission)) {
        try await repository.importCards(entries, now: transferNow, backup: { snapshot in
            #expect(snapshot.cards == before)
            throw CocoaError(.fileWriteNoPermission)
        })
    }
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failing.importCards(entries, now: transferNow, backup: { _ in })
    }
    #expect(try await repository.cards(scope: .all) == before)
    #expect(try await repository.pendingOutbox() == outbox)
    #expect(try await repository.importCards(entries, now: transferNow, backup: { _ in }) == 1)
}

@Test func replaceRestoreCommitsOneInboxAndNormalOutboxOrRollsBack() async throws {
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    try await repository.bootstrap(now: transferNow)
    let before = try await repository.transferSnapshot()
    let outbox = try await repository.pendingOutbox()
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let restore = TransferSnapshot(cards: entries.map(\.card), lines: entries.flatMap(\.lines))
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) { try await failing.replaceUserData(restore, now: transferNow) }
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == outbox)
    try await repository.replaceUserData(restore, now: transferNow)
    let cards = try await repository.cards(scope: .all)
    #expect(cards.count == 1)
    #expect(cards.first?.title == "Garden checklist")
    #expect(cards.first?.isInbox == true)
    #expect(try await repository.lines(cardID: entries[0].card.id).count == 4)
    let changes = try await repository.pendingOutbox()
    #expect(changes.contains { $0.entityID == before.cards[0].id.rawValue && $0.operation == .delete })
    #expect(changes.contains { $0.entityID == entries[0].card.id.rawValue && $0.operation == .upsert })
    #expect(try await repository.resetGeneration() == nil)
}

@Test func differentWindowsFilesWithOverlappingNoteIDsImportOnlyNewNotes() async throws {
    func source(_ ids: [String]) throws -> Data {
        let notes: [[String: Any]] = ids.enumerated().map { index, id in ["Id": id, "Title": "Note \(index)"] }
        return try JSONSerialization.data(withJSONObject: ["SchemaVersion": 1, "Notes": notes], options: .sortedKeys)
    }
    let a = "11111111-1111-1111-1111-111111111111"
    let b = "22222222-2222-2222-2222-222222222222"
    let c = "33333333-3333-3333-3333-333333333333"
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: transferNow)
    let first = try WindowsNotesImporter.decode(source([a, b]), now: transferNow, timeZone: .gmt)
    let second = try WindowsNotesImporter.decode(source([b, c]), now: transferNow, timeZone: .gmt)
    #expect(try await repository.importCards(first, now: transferNow, backup: { _ in }) == 2)
    #expect(try await repository.importCards(second, now: transferNow, backup: { _ in }) == 1)
    #expect(try await repository.cards(scope: .all).count == 4)
}
