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
