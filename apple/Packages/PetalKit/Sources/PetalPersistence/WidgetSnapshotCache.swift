import Foundation
import CryptoKit
import Darwin
import PetalCore

/// Minimal, versioned presentation data. The directory is separate from the database.
public actor WidgetSnapshotCache {
    private struct Envelope: Codable {
        let version: Int
        let snapshot: WidgetSnapshot
    }
    private let resolveDirectory: @Sendable () throws -> URL

    public init(directory: URL) { resolveDirectory = { directory } }
    public init(directory: @escaping @Sendable () throws -> URL) { resolveDirectory = directory }

    public func store(_ snapshot: WidgetSnapshot, size: WidgetDisplaySize, now: Date, calendar: Calendar) throws {
        try withDirectoryLock { directory in
            try prune(directory: directory, now: now)
            if snapshot.cardState == .unavailable || snapshot.cardState == .archived || snapshot.cardState == .trashed {
                // Confirmed inactive identity invalidates every size/day, not just this request.
                for url in try files(in: directory) where url.lastPathComponent.hasPrefix(snapshot.cardID.rawValue.uuidString + "-") {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            guard snapshot.cardState == .normal || snapshot.cardState == .empty else { return }
            let url = fileURL(directory: directory, cardID: snapshot.cardID, size: size, now: now, calendar: calendar)
            try JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot)).write(to: url, options: .atomic)
            let retained = try files(in: directory).sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
            for old in retained.prefix(max(0, retained.count - 32)) { try FileManager.default.removeItem(at: old) }
        }
    }

    public func load(cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) throws -> WidgetSnapshot? {
        try withDirectoryLock { directory in
            try prune(directory: directory, now: now)
            let url = fileURL(directory: directory, cardID: cardID, size: size, now: now, calendar: calendar)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).snapshot
            guard value.cardID == cardID, value.nextRefresh == calendar.dateInterval(of: .day, for: now)!.end,
                  value.visibleLines.count <= (size == .medium ? 5 : 10), value.hiddenCount >= 0,
                  value.cardState == .normal || value.cardState == .empty else {
                try FileManager.default.removeItem(at: url)
                return nil
            }
            return value
        }
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func prune(directory: URL, now: Date) throws {
        for url in try files(in: directory) {
            let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard let envelope, envelope.version == 1, envelope.snapshot.nextRefresh > now else {
                try FileManager.default.removeItem(at: url)
                continue
            }
        }
    }

    /// One advisory lock serializes independent extension instances and invalidation.
    /// Atomic replacement prevents partial JSON from becoming a visible last-good entry.
    private func withDirectoryLock<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = try resolveDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".cache.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body(directory)
    }

    private func fileURL(directory: URL, cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) -> URL {
        let day = calendar.dateInterval(of: .day, for: now)!
        let identity = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(day.start.timeIntervalSince1970)|\(day.end.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(cardID.rawValue.uuidString)-\(size == .medium ? "medium" : "large")-\(digest).json")
    }
}
