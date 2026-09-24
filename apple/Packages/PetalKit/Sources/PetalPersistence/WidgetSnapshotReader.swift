import Foundation
import PetalCore

/// The extension supplies an App Group cache for recovery across process launches.
public actor WidgetSnapshotReader {
    private let openRepository: @Sendable () async throws -> any PetalRepository
    private let persistentCache: WidgetSnapshotCache?
    private var cache: [String: WidgetSnapshot] = [:]

    public init(cache: WidgetSnapshotCache? = nil, openRepository: @escaping @Sendable () async throws -> any PetalRepository) {
        self.persistentCache = cache
        self.openRepository = openRepository
    }

    public func snapshot(cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) async -> WidgetSnapshot {
        let key = cardID.rawValue.uuidString + (size == .medium ? ".medium" : ".large")
        let token = try? await persistentCache?.beginRead(cardID: cardID)
        do {
            let repository = try await openRepository()
            let value = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: cardID, size: size, now: now, calendar: calendar)
            if let persistentCache {
                if value.cardState == .normal || value.cardState == .empty {
                    // A stale token cannot repopulate a cache invalidated by another reader.
                    if let token { try? await persistentCache.store(value, token: token, size: size, now: now, calendar: calendar) }
                } else {
                    try? await persistentCache.invalidate(cardID: cardID)
                }
            } else {
                if cache.count >= 32 { cache.removeAll() }
                if value.cardState == .normal || value.cardState == .empty { cache[key] = value }
                else { cache = cache.filter { !$0.key.hasPrefix(cardID.rawValue.uuidString) } }
            }
            return value
        } catch {
            // A time-zone/calendar change can also make a completion belong to yesterday.
            let nextRefresh = calendar.dateInterval(of: .day, for: now)!.end
            let cached: WidgetSnapshot?
            if let persistentCache {
                cached = try? await persistentCache.load(cardID: cardID, size: size, now: now, calendar: calendar)
            } else {
                cached = cache[key].flatMap { now < $0.nextRefresh && $0.nextRefresh == nextRefresh ? $0 : nil }
            }
            return WidgetSnapshot(cardID: cardID, title: cached?.title ?? "", visibleLines: cached?.visibleLines ?? [],
                hiddenCount: cached?.hiddenCount ?? 0, cardState: .persistenceError, syncBadge: cached?.syncBadge,
                nextRefresh: nextRefresh)
        }
    }
}
