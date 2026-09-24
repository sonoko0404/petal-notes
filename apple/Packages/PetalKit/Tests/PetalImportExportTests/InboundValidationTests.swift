import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalImportExport

private let validationNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test(arguments: ["activeDeleted", "trashUndated", "archivedInbox"], [false, true])
func malformedInboundCannotPoisonBackupOrClearLocalEdits(kind: String, newerGeneration: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open()
    try await repository.bootstrap(now: validationNow)
    let local = try #require(await repository.cards(scope: .active).first)
    let journal = try await repository.pendingOutbox()
    var poison = local
    poison.title = "Quarantined title"; poison.modifiedAt = validationNow.addingTimeInterval(10); poison.deviceID = "remote"
    switch kind {
    case "activeDeleted": poison.deletedAt = validationNow
    case "trashUndated": poison.status = .trashed; poison.isInbox = false
    default: poison.status = .archived; poison.archivedAt = validationNow
    }
    let generation = newerGeneration ? ResetGeneration(id: UUID(), modifiedAt: validationNow,
        deviceID: "remote", isReplacement: true) : .initial
    let record = ReplicatedRecord(payload: .card(poison), generation: generation)
    try await repository.applyInbound([record], token: Data([7]), now: validationNow)
    #expect(try await repository.card(id: local.id) == local)
    #expect(try await repository.pendingOutbox() == journal)
    #expect(try await repository.syncSnapshot().generation == .initial)
    let reopened = try open()
    #expect(try await reopened.syncSnapshot().token == Data([7]))
    let artifacts = try await reopened.takeUnpresentedConflicts(now: validationNow)
    #expect(artifacts.count == 1)
    #expect(try JSONDecoder().decode(Card.self, from: #require(artifacts.first).losingPayload).title == "Quarantined title")
    try await reopened.applyInbound([record], token: Data([8]), now: validationNow)
    #expect(try await reopened.takeUnpresentedConflicts(now: validationNow).isEmpty)
    _ = try PetalBackupCodec.encode(PetalBackup(snapshot: await reopened.transferSnapshot(), settings: TransferSettings()))
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: validationNow, timeZone: .gmt)
    #expect(try await reopened.importCards(entries, now: validationNow) { before in
        _ = try PetalBackupCodec.encode(PetalBackup(snapshot: before, settings: TransferSettings()))
    } == entries.count)
    var repaired = local
    repaired.title = "Repaired"; repaired.modifiedAt = validationNow.addingTimeInterval(20); repaired.deviceID = "remote"
    try await reopened.applyInbound([ReplicatedRecord(payload: .card(repaired), generation: .initial)], token: Data([9]), now: validationNow)
    #expect(try await reopened.card(id: local.id)?.title == "Repaired")
}

@Test(arguments: ["textReminder", "textCompleted", "negativeStreak", "invalidMinute", "invalidZone", "foreignKey"])
func malformedLineIsQuarantinedWithoutLosingCanonicalParentOrJournal(kind: String) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Parent", now: validationNow)
    let other = try await repository.createCard(title: "Other", now: validationNow)
    let local = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Local"), now: validationNow)
    let journal = try await repository.pendingOutbox()
    var poison = local
    poison.text = "Quarantined line"; poison.modifiedAt = validationNow.addingTimeInterval(10); poison.deviceID = "remote"
    switch kind {
    case "textReminder": poison.kind = .text; poison.reminder = Reminder(rule: .oneTime(validationNow), isEnabled: true)
    case "textCompleted": poison.kind = .text; poison.isCompleted = true
    case "negativeStreak": poison.dailyStreak = -1
    case "invalidMinute": poison.reminder = Reminder(rule: .daily(localMinute: 1440, timeZoneIdentifier: "UTC"), isEnabled: true)
    case "invalidZone": poison.reminder = Reminder(rule: .daily(localMinute: 10, timeZoneIdentifier: "not-a-zone"), isEnabled: true)
    default:
        poison = CardLine(id: local.id, cardID: other.id, kind: .todo, text: "Quarantined line", sortIndex: 0,
            isCompleted: false, completedAt: nil, lastDailyCompletionKey: nil, dailyStreak: 0, reminder: nil,
            createdAt: validationNow, modifiedAt: validationNow.addingTimeInterval(10), deletedAt: nil, revision: 2, deviceID: "remote")
    }
    try await repository.applyInbound([ReplicatedRecord(payload: .line(poison), generation: .initial)], token: Data([1]), now: validationNow)
    #expect(try await repository.lines(cardID: card.id) == [local])
    #expect(try await repository.lines(cardID: other.id).isEmpty)
    #expect(try await repository.pendingOutbox() == journal)
    #expect(try await repository.conflicts().count == 1)
    _ = try PetalBackupCodec.encode(PetalBackup(snapshot: await repository.transferSnapshot(), settings: TransferSettings()))
    if kind != "foreignKey" {
        await #expect(throws: (any Error).self) {
            try await repository.replaceUserData(TransferSnapshot(cards: [card], lines: [poison]), now: validationNow)
        }
    }
    var repair = local
    repair.text = "Repaired line"; repair.modifiedAt = validationNow.addingTimeInterval(20); repair.deviceID = "remote"
    try await repository.applyInbound([ReplicatedRecord(payload: .line(repair), generation: .initial)], token: Data([2]), now: validationNow)
    #expect(try await repository.lines(cardID: card.id).first?.text == "Repaired line")
}

@Test(arguments: ["oversize", "nonfinite", "activeArchived", "reminderDate", "badRedaction"])
func invalidInboundRetainsOnlyBoundedSafePayload(kind: String) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let local = try await repository.createCard(title: "Safe", now: validationNow)
    var card = local
    card.modifiedAt = validationNow.addingTimeInterval(10)
    var payload: ReplicatedRecord.Payload
    switch kind {
    case "oversize": card.deletedAt = validationNow; card.title = String(repeating: "s", count: 70_000); payload = .card(card)
    case "nonfinite": card.modifiedAt = Date(timeIntervalSince1970: .infinity); payload = .card(card)
    case "activeArchived": card.archivedAt = validationNow; payload = .card(card)
    case "badRedaction": payload = .tombstone(SyncTombstone(id: UUID(), entity: .card, entityID: local.id.rawValue,
        deletedAt: Date(timeIntervalSince1970: .infinity), deviceID: "remote", revision: 2))
    default:
        var line = try await repository.addLine(NewLineDraft(cardID: local.id, kind: .todo, text: "Safe todo"), now: validationNow)
        line.reminder = Reminder(rule: .oneTime(validationNow), isEnabled: true, lastDeliveredAt: Date(timeIntervalSince1970: .infinity))
        payload = .line(line)
    }
    let before = try await repository.transferSnapshot()
    let journal = try await repository.pendingOutbox()
    try await repository.applyInbound([ReplicatedRecord(payload: payload, generation: .initial)], token: Data([2]), now: validationNow)
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == journal)
    #expect(try await repository.syncSnapshot().token == Data([2]))
    let artifact = try #require(await repository.conflicts().first)
    #expect(artifact.losingPayload.count <= 65_536)
    #expect(artifact.inboundIssue != nil)
    _ = try PetalBackupCodec.encode(PetalBackup(snapshot: await repository.transferSnapshot(), settings: TransferSettings()))
}

@Test func quarantineAndMixedValidBatchCheckpointRollbackTogether() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open(fault: RepositoryFaultInjector = .none) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }), faultInjector: fault)
    }
    let repository = try open()
    let local = try await repository.createCard(title: "Valid", now: validationNow)
    let other = try await repository.createCard(title: "Other", now: validationNow)
    let before = try await repository.transferSnapshot()
    let journal = try await repository.pendingOutbox()
    var bad = local; bad.deletedAt = validationNow; bad.modifiedAt = validationNow.addingTimeInterval(10)
    var good = other; good.title = "Remote valid"; good.modifiedAt = validationNow.addingTimeInterval(10)
    let records = [bad, good].map { ReplicatedRecord(payload: .card($0), generation: .initial) }
    let failed = try open(fault: .failOnceBeforeSave)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await failed.applyInbound(records, token: Data([3]), now: validationNow)
    }
    let reopened = try open()
    #expect(try await reopened.transferSnapshot() == before)
    #expect(try await reopened.pendingOutbox() == journal)
    #expect(try await reopened.conflicts().isEmpty)
    #expect(try await reopened.syncSnapshot().token == nil)
    try await reopened.applyInbound(records, token: Data([3]), now: validationNow)
    #expect(try await reopened.card(id: local.id) == local)
    #expect(try await reopened.card(id: other.id)?.title == "Remote valid")
    #expect(try await reopened.conflicts().count == 1)
    #expect(try await reopened.syncSnapshot().token == Data([3]))
    try await reopened.purgeExpiredConflicts(now: validationNow.addingTimeInterval(2_592_001))
    #expect(try await reopened.conflicts().isEmpty)
}
