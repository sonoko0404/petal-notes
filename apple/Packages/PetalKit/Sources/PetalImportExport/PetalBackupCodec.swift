import Foundation
import PetalCore
import PetalPersistence

public struct TransferSettings: Codable, Sendable, Equatable {
    public var notificationSoundEnabled: Bool
    public init(notificationSoundEnabled: Bool = false) { self.notificationSoundEnabled = notificationSoundEnabled }
}

public struct PetalBackup: Sendable {
    public var snapshot: TransferSnapshot
    public var settings: TransferSettings
    public init(snapshot: TransferSnapshot, settings: TransferSettings) { self.snapshot = snapshot; self.settings = settings }
}

public enum PetalBackupCodec {
    private static let cardFields: Set<String> = ["id", "title", "status", "themeID", "isInbox", "createdAt", "modifiedAt", "archivedAt", "deletedAt"]
    private static let lineFields: Set<String> = ["id", "cardID", "kind", "text", "sortIndex", "isCompleted", "completedAt", "lastDailyCompletionKey", "dailyStreak", "reminder", "createdAt", "modifiedAt", "deletedAt"]

    public static func encode(_ backup: PetalBackup) throws -> Data {
        try backup.snapshot.validate()
        let cards = try backup.snapshot.cards.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            .map { try sanitized($0, fields: cardFields) }
        let lines = try backup.snapshot.lines.sorted {
            if $0.cardID != $1.cardID { return $0.cardID.rawValue.uuidString < $1.cardID.rawValue.uuidString }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }.map { try sanitized($0, fields: lineFields) }
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup.settings))
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "cards": cards, "lines": lines,
            "settings": settings], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    public static func decode(_ data: Data) throws -> PetalBackup {
        struct Header: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard version == 1 else { throw TransferError.unsupportedVersion(version) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cardObjects = object["cards"] as? [[String: Any]],
              let lineObjects = object["lines"] as? [[String: Any]],
              let settingsObject = object["settings"] as? [String: Any] else { throw TransferError.invalidDocument }
        let cards = try cardObjects.map { try domain(Card.self, object: $0, fields: cardFields) }
        let lines = try lineObjects.map { try domain(CardLine.self, object: $0, fields: lineFields) }
        let settings = try JSONDecoder().decode(TransferSettings.self,
            from: JSONSerialization.data(withJSONObject: settingsObject))
        let snapshot = TransferSnapshot(cards: cards, lines: lines)
        try snapshot.validate()
        return PetalBackup(snapshot: snapshot, settings: settings)
    }

    private static func sanitized<T: Encodable>(_ value: T, fields: Set<String>) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw TransferError.invalidDocument
        }
        return object.filter { fields.contains($0.key) }
    }

    private static func domain<T: Decodable>(_ type: T.Type, object: [String: Any], fields: Set<String>) throws -> T {
        var value = object.filter { fields.contains($0.key) }
        value["deviceID"] = ""
        value["revision"] = 1
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
