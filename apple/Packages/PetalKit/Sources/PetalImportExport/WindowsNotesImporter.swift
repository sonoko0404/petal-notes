import Foundation
import PetalCore
import PetalPersistence
import CryptoKit

public enum WindowsNotesImporter {
    public static func decode(_ data: Data, now: Date, timeZone: TimeZone,
                              fallbackTitle: String = "Imported reminder") throws -> [ImportedCard] {
        struct Header: Decodable { let SchemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).SchemaVersion
        guard version == 1 else { throw TransferError.unsupportedVersion(version) }
        let source = try JSONDecoder().decode(WindowsSchemaV1.self, from: data)
        guard Set(source.Notes.map(\.Id)).count == source.Notes.count else { throw TransferError.invalidDocument }
        return try source.Notes.map { note in
            let id = CardID(rawValue: UUID())
            let deletedAt = try note.DeletedAt.map(TransferDate.parse)
            let card = Card(id: id, title: note.Title ?? "", status: deletedAt == nil ? .active : .trashed,
                themeID: ["pink": ThemeID.sakura, "blue": .sky][note.Theme ?? ""]
                    ?? ThemeID(rawValue: note.Theme ?? "cream") ?? .cream, isInbox: false,
                createdAt: now, modifiedAt: now, archivedAt: nil, deletedAt: deletedAt, revision: 1, deviceID: "")
            var lines: [CardLine] = []
            func append(_ text: String, kind: LineKind, done: Bool = false) {
                lines.append(CardLine(id: LineID(rawValue: UUID()), cardID: id, kind: kind, text: text,
                    sortIndex: Int64(lines.count), isCompleted: done, completedAt: done ? now : nil,
                    lastDailyCompletionKey: nil, dailyStreak: 0, reminder: nil, createdAt: now,
                    modifiedAt: now, deletedAt: nil, revision: 1, deviceID: ""))
            }
            for paragraph in (note.Body ?? "").components(separatedBy: .newlines)
                where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                append(paragraph, kind: .text)
            }
            for todo in note.Todos { append(todo.Text ?? "", kind: .todo, done: todo.Done) }
            let due = try note.Reminder.Due.map(TransferDate.parse)
            if note.Reminder.Daily || due != nil {
                let rule: ReminderRule = note.Reminder.Daily
                    ? .daily(localMinute: min(23, max(0, note.Reminder.Hour)) * 60 + min(59, max(0, note.Reminder.Minute)),
                             timeZoneIdentifier: timeZone.identifier)
                    : .oneTime(due!)
                if !lines.contains(where: { $0.kind == .todo && !$0.isCompleted }) {
                    let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    append(title.isEmpty ? fallbackTitle : title, kind: .todo)
                }
                let index = lines.firstIndex { $0.kind == .todo && !$0.isCompleted }!
                lines[index].reminder = Reminder(rule: rule, isEnabled: true)
            }
            var input = data
            input.append(contentsOf: note.Id.uuidString.lowercased().utf8)
            let fingerprint = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
            return ImportedCard(card: card, lines: lines, fingerprint: fingerprint, sourceNoteID: note.Id)
        }
    }
}
