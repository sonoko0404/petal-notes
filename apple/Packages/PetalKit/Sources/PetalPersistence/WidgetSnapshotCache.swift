import Foundation
import CryptoKit
import Darwin
import PetalCore

public struct WidgetSnapshotReadToken: Sendable {
    fileprivate let cardID: CardID
    fileprivate let generation: UUID
}

/// Minimal, versioned presentation data. The directory is separate from the database.
public actor WidgetSnapshotCache {
    private struct Envelope: Codable {
        let version: Int
        let generation: UUID
        let snapshot: WidgetSnapshot
    }
    private struct Generation: Codable {
        let cardID: CardID
        let value: UUID
    }
    private struct Metadata: Codable {
        let version: Int
        var generations: [Generation]
    }
    private let resolveDirectory: @Sendable () throws -> URL

    public init(directory: URL) { resolveDirectory = { directory } }
    public init(directory: @escaping @Sendable () throws -> URL) { resolveDirectory = directory }

    /// Capture before repository reads. UUID generations are never reused after invalidation.
    public func beginRead(cardID: CardID) throws -> WidgetSnapshotReadToken {
        try withDirectoryLock { directory in
            var metadata = try readMetadata(in: directory)
            let generation = metadata.generations.first { $0.cardID == cardID } ?? Generation(cardID: cardID, value: UUID())
            metadata.generations.removeAll { $0.cardID == cardID }
            metadata.generations.append(generation)
            try writeMetadata(metadata, in: directory)
            return WidgetSnapshotReadToken(cardID: cardID, generation: generation.value)
        }
    }

    public func invalidate(cardID: CardID) throws {
        try withDirectoryLock { directory in
            var metadata = try readMetadata(in: directory)
            metadata.generations.removeAll { $0.cardID == cardID }
            metadata.generations.append(Generation(cardID: cardID, value: UUID()))
            // Persist the fence first: even interrupted cleanup leaves old entries ineligible.
            try writeMetadata(metadata, in: directory)
            for url in try files(in: directory) where url.lastPathComponent.hasPrefix(cardID.rawValue.uuidString + "-") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func store(_ snapshot: WidgetSnapshot, token: WidgetSnapshotReadToken, size: WidgetDisplaySize, now: Date, calendar: Calendar) throws {
        try withDirectoryLock { directory in
            let metadata = try readMetadata(in: directory)
            guard token.cardID == snapshot.cardID,
                  metadata.generations.first(where: { $0.cardID == snapshot.cardID })?.value == token.generation else { return }
            try prune(directory: directory, now: now)
            guard snapshot.cardState == .normal || snapshot.cardState == .empty else { return }
            let url = fileURL(directory: directory, cardID: snapshot.cardID, size: size, now: now, calendar: calendar)
            try JSONEncoder().encode(Envelope(version: 2, generation: token.generation, snapshot: snapshot)).write(to: url, options: .atomic)
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
            let metadata = try readMetadata(in: directory)
            try prune(directory: directory, now: now)
            let url = fileURL(directory: directory, cardID: cardID, size: size, now: now, calendar: calendar)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            let value = envelope.snapshot
            guard metadata.generations.first(where: { $0.cardID == cardID })?.value == envelope.generation,
                  value.cardID == cardID, value.nextRefresh == calendar.dateInterval(of: .day, for: now)!.end,
                  value.visibleLines.count <= (size == .medium ? 5 : 10), value.hiddenCount >= 0,
                  value.cardState == .normal || value.cardState == .empty else {
                try FileManager.default.removeItem(at: url)
                return nil
            }
            return value
        }
    }

    private func readMetadata(in directory: URL) throws -> Metadata {
        let url = directory.appendingPathComponent("generations.metadata")
        if let data = try? Data(contentsOf: url),
           let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
           metadata.version == 1, metadata.generations.count <= 128,
           Set(metadata.generations.map(\.cardID)).count == metadata.generations.count {
            return metadata
        }
        // Missing/corrupt/future metadata invalidates every existing token and snapshot.
        // Repair starts empty; new reads receive fresh UUIDs, never a reused counter value.
        let empty = Metadata(version: 1, generations: [])
        try writeMetadata(empty, in: directory)
        for url in try files(in: directory) { try FileManager.default.removeItem(at: url) }
        return empty
    }

    private func writeMetadata(_ metadata: Metadata, in directory: URL) throws {
        let evicted = metadata.generations.prefix(max(0, metadata.generations.count - 128))
        let bounded = Metadata(version: 1, generations: Array(metadata.generations.suffix(128)))
        try JSONEncoder().encode(bounded).write(to: directory.appendingPathComponent("generations.metadata"), options: .atomic)
        for generation in evicted {
            for url in try files(in: directory) where url.lastPathComponent.hasPrefix(generation.cardID.rawValue.uuidString + "-") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func prune(directory: URL, now: Date) throws {
        for url in try files(in: directory) {
            let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard let envelope, envelope.version == 2, envelope.snapshot.nextRefresh > now else {
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
