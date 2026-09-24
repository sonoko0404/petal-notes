import Foundation

/// Case-sensitive System.Text.Json names from StickyNotes/Models.cs.
struct WindowsSchemaV1: Decodable {
    let SchemaVersion: Int
    let Notes: [Note]
    struct Note: Decodable {
        let Id: UUID
        let Title: String?
        let Body: String?
        let Theme: String?
        let DeletedAt: String?
        let Todos: [Todo]
        let Reminder: LegacyReminder
        enum CodingKeys: String, CodingKey { case Id, Title, Body, Theme, DeletedAt, Todos, Reminder }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Id = try c.decode(UUID.self, forKey: .Id)
            Title = try c.decodeIfPresent(String.self, forKey: .Title)
            Body = try c.decodeIfPresent(String.self, forKey: .Body)
            Theme = try c.decodeIfPresent(String.self, forKey: .Theme)
            DeletedAt = try c.decodeIfPresent(String.self, forKey: .DeletedAt)
            Todos = try c.contains(.Todos) ? c.decode([Todo].self, forKey: .Todos) : []
            Reminder = try c.contains(.Reminder) ? c.decode(LegacyReminder.self, forKey: .Reminder) : LegacyReminder()
        }
    }
    struct Todo: Decodable {
        let Text: String?; let Done: Bool
        enum CodingKeys: String, CodingKey { case Text, Done }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Text = try c.decodeIfPresent(String.self, forKey: .Text)
            Done = try c.contains(.Done) ? c.decode(Bool.self, forKey: .Done) : false
        }
    }
    struct LegacyReminder: Decodable {
        let Due: String?
        let Daily: Bool
        let Hour: Int
        let Minute: Int
        let Pending: Bool
        init() { Due = nil; Daily = false; Hour = 9; Minute = 0; Pending = false }
        enum CodingKeys: String, CodingKey { case Due, Daily, Hour, Minute, Pending }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Due = try c.decodeIfPresent(String.self, forKey: .Due)
            Daily = try c.contains(.Daily) ? c.decode(Bool.self, forKey: .Daily) : false
            Hour = try c.contains(.Hour) ? c.decode(Int.self, forKey: .Hour) : 9
            Minute = try c.contains(.Minute) ? c.decode(Int.self, forKey: .Minute) : 0
            Pending = try c.contains(.Pending) ? c.decode(Bool.self, forKey: .Pending) : false
        }
    }
}

public enum TransferError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case invalidDocument
    case destinationExists
}

enum TransferDate {
    static func parse(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw TransferError.invalidDocument }
        return date
    }
}
