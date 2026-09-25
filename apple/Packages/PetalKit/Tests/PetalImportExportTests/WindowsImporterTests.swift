import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalImportExport

let transferNow = Date(timeIntervalSince1970: 1_800_000_000)
func windowsFixture() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/windows-v1.json"))
}

@Test func windowsThemesMapPinkAndBlueOneToOne() throws {
    for (old, expected) in [("pink", ThemeID.sakura), ("blue", .sky)] {
        let data = Data(String(decoding: try windowsFixture(), as: UTF8.self)
            .replacingOccurrences(of: "\"mint\"", with: "\"\(old)\"").utf8)
        #expect(try WindowsNotesImporter.decode(data, now: transferNow, timeZone: .gmt).first?.card.themeID == expected)
    }
}

@Test func windowsUsesModelDefaultsAndRejectsFutureVersionBeforeReadingNotes() throws {
    let data = Data(#"{"SchemaVersion":1,"Notes":[{"Id":"4dbfd594-1ee5-472b-8a00-687675b485f7"}]}"#.utf8)
    let entry = try #require(WindowsNotesImporter.decode(data, now: transferNow, timeZone: .gmt).first)
    #expect(entry.card.title.isEmpty)
    #expect(entry.card.themeID == .cream)
    #expect(entry.lines.isEmpty)
    #expect(throws: TransferError.unsupportedVersion(2)) {
        try WindowsNotesImporter.decode(Data(#"{"SchemaVersion":2}"#.utf8), now: transferNow, timeZone: .gmt)
    }
}

@Test func windowsMapsParagraphsCompletionReminderAndIgnoresHiddenState() throws {
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let entry = try #require(entries.first)
    #expect(entries.count == 1)
    #expect(entry.card.title == "Garden checklist")
    #expect(entry.card.themeID == .mint)
    #expect(entry.card.status == .active)
    #expect(entry.lines.map(\.text) == ["First paragraph", "Second paragraph", "Seeds", "Water"])
    #expect(entry.lines.map(\.kind) == [.text, .text, .todo, .todo])
    #expect(entry.lines.map(\.isCompleted) == [false, false, true, false])
    #expect(entry.lines.map(\.sortIndex) == [0, 1, 2, 3])
    #expect(entry.lines[2].reminder == nil)
    #expect(entry.lines[3].reminder?.rule == .oneTime(Date(timeIntervalSince1970: 1_790_299_800)))
    #expect(entry.fingerprint == "55b1d91f0dd0e546d469e4b7fe863ad1b512bdafc1b46a5e1f55531b16ef6b07")
}

@Test func dailyReminderUsesExplicitZoneClampedWallClockAndFallbackTodo() throws {
    let data = Data(#"{"SchemaVersion":1,"Notes":[{"Id":"4dbfd594-1ee5-472b-8a00-687675b485f7","Title":"  ","Todos":[{"Text":"Done","Done":true}],"Reminder":{"Due":"2026-09-25T09:30:00+08:00","Daily":true,"Hour":30,"Minute":-5,"Pending":true}}]}"#.utf8)
    let entry = try #require(WindowsNotesImporter.decode(data, now: transferNow,
        timeZone: TimeZone(identifier: "Asia/Shanghai")!, fallbackTitle: "导入的提醒").first)
    #expect(entry.lines.map(\.text) == ["Done", "导入的提醒"])
    #expect(entry.lines[0].isCompleted)
    #expect(!entry.lines[1].isCompleted)
    #expect(entry.lines[1].reminder?.rule == .daily(localMinute: 1380, timeZoneIdentifier: "Asia/Shanghai"))
}

@Test(arguments: ["2026-02-30T09:30:00Z", "2025-02-29T09:30:00Z", "2026-13-01T09:30:00Z",
    "2026-09-25T24:00:00Z", "2026-09-25T09:60:00Z", "2026-09-25T09:30:60Z",
    "2026-09-25T09:30:00Zjunk", "2026-09-25T09:30:00Z\n", "2026-09-25T09:30:00",
    "2026-09-25T09:30:00+14:01", "2026-09-25T09:30:00+08:60", "0000-01-01T00:00:00Z"])
func windowsRejectsImpossibleOrPartiallyConsumedDate(_ value: String) throws {
    #expect(throws: TransferError.invalidDocument) { try TransferDate.parse(value) }
}

@Test(arguments: ["2024-02-29T01:30:00Z", "2024-02-29T09:30:00+08:00", "2024-02-28T20:00:00-05:30"])
func windowsAcceptsValidLeapDateAndOffsets(_ value: String) throws {
    #expect(try TransferDate.parse(value) == Date(timeIntervalSince1970: 1_709_170_200))
    #expect(try TransferDate.parse("2024-02-29T01:30:00.1234567Z").timeIntervalSince1970 == 1_709_170_200.1234567)
}
