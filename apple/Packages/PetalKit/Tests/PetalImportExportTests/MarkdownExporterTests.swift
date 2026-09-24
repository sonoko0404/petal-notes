import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalImportExport

@Test func markdownUsesCheckboxesLocalizedReminderAndStableSafeCollisionNames() throws {
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let card = entries[0].card
    func named(_ id: String) -> Card {
        Card(id: CardID(rawValue: UUID(uuidString: id)!), title: "../CON/", status: .active,
            themeID: .cream, isInbox: false, createdAt: transferNow, modifiedAt: transferNow,
            archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "")
    }
    let first = named("12345678-1111-1111-1111-111111111111")
    let second = named("12345678-2222-2222-2222-222222222222")
    let snapshot = TransferSnapshot(cards: [second, card, first], lines: entries[0].lines.reversed())
    let documents = try MarkdownExporter.documents(snapshot, languageCode: "zh-Hans")
    #expect(documents.count == 3)
    let key = try #require(documents.keys.first { $0.hasPrefix("Garden checklist-") })
    let text = String(decoding: try #require(documents[key]), as: UTF8.self)
    #expect(text.contains("# Garden checklist\n\nFirst paragraph\n\nSecond paragraph\n\n- [x] Seeds\n\n- [ ] Water"))
    #expect(text.contains("    提醒：2026-09-25T01:30:00Z"))
    #expect(documents.keys.allSatisfy { !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") })
    #expect(Set(documents.keys.map { $0.lowercased() }).count == 3)
    #expect(documents == (try MarkdownExporter.documents(TransferSnapshot(cards: snapshot.cards.reversed(), lines: snapshot.lines.reversed()), languageCode: "zh-Hans")))
}

@Test func markdownPublishesCompleteNewFolderAndLeavesExistingFolderUntouched() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Petal Markdown Export")
    let entries = try WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt)
    let snapshot = TransferSnapshot(cards: entries.map(\.card), lines: entries.flatMap(\.lines))
    try MarkdownExporter.write(snapshot, to: root)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    #expect(throws: (any Error).self) { try MarkdownExporter.write(snapshot, to: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Petal Markdown Export"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
}

@Test func markdownNormalizesMultilineTodoToPortableIndentedLF() throws {
    let entry = try #require(WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt).first)
    var line = entry.lines[3]
    line.text = "alpha\r\nbeta\rgamma"
    line.reminder = nil
    let documents = try MarkdownExporter.documents(TransferSnapshot(cards: [entry.card], lines: [line]))
    let text = String(decoding: try #require(documents.values.first), as: UTF8.self)
    #expect(text.hasSuffix("- [ ] alpha\n    beta\n    gamma\n"))
    #expect(!text.contains("\r"))
}

@Test func markdownStagesAndPublishesOnlyInsideSelectedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let selected = root.appendingPathComponent("Selected")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = try #require(WindowsNotesImporter.decode(windowsFixture(), now: transferNow, timeZone: .gmt).first)
    try MarkdownExporter.write(TransferSnapshot(cards: [entry.card], lines: entry.lines), to: selected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Selected"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: selected.path) == ["Petal Markdown Export"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: selected.appendingPathComponent("Petal Markdown Export").path).count == 1)
}
