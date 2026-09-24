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
        // DateTimeOffset's serialized shape: full date/time, optional 1–7 decimal
        // digits, and Z or a bounded signed offset. No formatter normalization.
        let expression = try NSRegularExpression(pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,7}))?(Z|[+-][0-9]{2}:[0-9]{2})\z"#)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            throw TransferError.invalidDocument
        }
        func field(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
        let year = Int(field(1))!, month = Int(field(2))!, day = Int(field(3))!
        let hour = Int(field(4))!, minute = Int(field(5))!, second = Int(field(6))!
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...9999).contains(year), (1...12).contains(month), (1...days[month - 1]).contains(day),
              hour < 24, minute < 60, second < 60 else { throw TransferError.invalidDocument }
        let zone = field(8)
        var offset = 0
        if zone != "Z" {
            let parts = zone.dropFirst().split(separator: ":").map { Int($0)! }
            guard parts[0] <= 14, parts[1] < 60, parts[0] != 14 || parts[1] == 0 else {
                throw TransferError.invalidDocument
            }
            offset = (parts[0] * 3600 + parts[1] * 60) * (zone.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
            hour: hour, minute: minute, second: second)) else { throw TransferError.invalidDocument }
        return date.addingTimeInterval((Double("0." + field(7)) ?? 0) - Double(offset))
    }
}
