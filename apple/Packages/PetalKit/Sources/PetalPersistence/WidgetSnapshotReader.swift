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
        if persistentCache != nil && token == nil {
            // Without a durable token, a read cannot prove it predates or
            // follows a concurrent reset. Do not publish unfenced content.
            return WidgetSnapshot(cardID: cardID, title: "", visibleLines: [], hiddenCount: 0,
                cardState: .persistenceError, nextRefresh: calendar.dateInterval(of: .day, for: now)!.end)
        }
        do {
            let repository = try await openRepository()
            if let persistentCache, let token, let sync = repository as? any PetalSyncRepository {
                // The status read takes the shared store lock. A token obtained
                // after the precommit fence must never authorize old DB data.
                let generation = try await sync.widgetSyncStatus().generation.id
                guard try await persistentCache.isCurrent(token, repositoryGeneration: generation) else {
                    return redacted(cardID: cardID, nextRefresh: calendar.dateInterval(of: .day, for: now)!.end)
                }
            }
            let value = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: cardID, size: size, now: now, calendar: calendar)
            if let persistentCache {
                if let token, (try? await persistentCache.isCurrent(token)) != true {
                    return redacted(cardID: cardID, nextRefresh: value.nextRefresh)
                }
                if value.cardState == .normal || value.cardState == .empty {
                    // A stale token cannot repopulate a cache invalidated by another reader.
                    if let token,
                       (try? await persistentCache.store(value, token: token, size: size, now: now, calendar: calendar)) != true {
                        return redacted(cardID: cardID, nextRefresh: value.nextRefresh)
                    }
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

    private func redacted(cardID: CardID, nextRefresh: Date) -> WidgetSnapshot {
        WidgetSnapshot(cardID: cardID, title: "", visibleLines: [], hiddenCount: 0,
            cardState: .unavailable, nextRefresh: nextRefresh)
    }
}
