import Foundation
import PetalPersistence
import PetalCore
import Darwin

public enum MarkdownExporter {
    public static func documents(_ snapshot: TransferSnapshot, languageCode: String = "en") throws -> [String: Data] {
        try snapshot.validate()
        func localized(_ key: String) -> String { PetalStrings.text(key, languageCode: languageCode) }
        var result: [String: Data] = [:]
        var used = Set<String>()
        for card in snapshot.cards.sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) {
            let id = card.id.rawValue.uuidString.lowercased()
            let base = safeName(card.title)
            var name = "\(base)-\(id.prefix(8)).md"
            if !used.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                name = "\(base)-\(id).md"
                used.insert(name.precomposedStringWithCanonicalMapping.lowercased())
            }
            let title = card.title.components(separatedBy: .newlines).joined(separator: " ")
            var parts = ["# \(title)"]
            let lines = snapshot.lines.filter { $0.cardID == card.id && $0.deletedAt == nil }.sorted {
                $0.sortIndex == $1.sortIndex ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.sortIndex < $1.sortIndex
            }
            for line in lines {
                let normalized = line.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                var text = line.kind == .todo ? "- [\(line.isCompleted ? "x" : " ")] \(normalized.replacingOccurrences(of: "\n", with: "\n    "))" : normalized
                if let reminder = line.reminder {
                    let value: String
                    switch reminder.rule {
                    case .oneTime(let date): value = ISO8601DateFormatter().string(from: date)
                    case .daily(let minute, let zone):
                        value = "\(localized("ui.export_daily")) \(String(format: "%02d:%02d", minute / 60, minute % 60)) (\(zone))"
                    }
                    text += "\n    \(localized("ui.export_reminder"))\(value)"
                    if !reminder.isEnabled { text += localized("ui.export_disabled") }
                    if let snooze = reminder.snoozedUntil {
                        text += " · \(localized("ui.export_snooze"))\(ISO8601DateFormatter().string(from: snooze))"
                    }
                }
                parts.append(text)
            }
            result[name] = Data((parts.joined(separator: "\n\n") + "\n").utf8)
        }
        return result
    }

    /// `directory` is an existing directory explicitly granted by the user's picker.
    public static func write(_ snapshot: TransferSnapshot, to directory: URL, languageCode: String = "en") throws {
        let documents = try documents(snapshot, languageCode: languageCode)
        let folder = directory.appendingPathComponent("Petal Markdown Export", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw TransferError.destinationExists }
        let staging = directory.appendingPathComponent(".petal-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        for name in documents.keys.sorted() { try TransferFileWriter.write(documents[name]!, to: staging.appendingPathComponent(name)) }
        guard renamex_np(staging.path, folder.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func safeName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        var text = String(title.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        while text.utf8.count > 120 { text.removeLast() }
        if text.isEmpty { text = "Card" }
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(text.components(separatedBy: ".")[0].uppercased()) { text = "Card-" + text }
        return text
    }
}
