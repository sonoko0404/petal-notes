import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalImportExport

@Test func backupRoundTripPreservesUserFieldsAndExcludesReplicationIdentity() throws {
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    var card = try #require(entries.first?.card)
    card.deviceID = "PRIVATE_DEVICE"; card.revision = 42
    var lines = entries[0].lines
    lines[0].deviceID = "PRIVATE_DEVICE"; lines[0].revision = 55
    lines[3].dailyStreak = 4
    lines[3].lastDailyCompletionKey = "2026-09-24"
    lines[3].reminder = Reminder(rule: .daily(localMinute: 570, timeZoneIdentifier: "Asia/Shanghai"),
        isEnabled: true, snoozedUntil: transferNow, lastDeliveredAt: transferNow)
    let backup = PetalBackup(snapshot: TransferSnapshot(cards: [card], lines: lines), settings: TransferSettings(notificationSoundEnabled: true))
    let data = try PetalBackupCodec.encode(backup)
    let text = String(decoding: data, as: UTF8.self)
    for excluded in ["deviceID", "revision", "PRIVATE_DEVICE", "outbox", "fingerprint", "resetGeneration", "token", "widget", "notificationIdentifier"] {
        #expect(!text.contains(excluded))
    }
    let restored = try PetalBackupCodec.decode(data)
    card.deviceID = ""; card.revision = 1
    for i in lines.indices { lines[i].deviceID = ""; lines[i].revision = 1 }
    #expect(restored.snapshot.cards == [card])
    #expect(restored.snapshot.lines == lines)
    #expect(restored.settings.notificationSoundEnabled)
    #expect(try PetalBackupCodec.encode(restored) == data)
}

@Test func conflictCopiesEnterPortableBackupsOnlyAfterPersistentRecovery() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Original", now: transferNow)
    var losing = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Current value"), now: transferNow)
    losing.text = "Recoverable alternate"
    let artifact = try await repository.captureConflict(cardID: card.id, lineID: losing.id,
        losingPayload: JSONEncoder().encode(losing), now: transferNow)
    let before = try PetalBackupCodec.decode(PetalBackupCodec.encode(PetalBackup(
        snapshot: await repository.transferSnapshot(), settings: TransferSettings())))
    #expect(!before.snapshot.lines.contains { $0.text == "Recoverable alternate" })
    let recovered = try await repository.recoverConflict(id: artifact.id, now: transferNow)
    let after = try PetalBackupCodec.decode(PetalBackupCodec.encode(PetalBackup(
        snapshot: await repository.transferSnapshot(), settings: TransferSettings())))
    #expect(after.snapshot.lines.contains { $0.cardID == recovered && $0.text == "Recoverable alternate" })
    #expect(try await repository.conflicts().first?.losingPayload == artifact.losingPayload)
}
