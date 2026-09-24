import Foundation
import PetalCore

/// Shared by provider instances. Keeps a bounded, process-local last-good cache;
/// WidgetKit owns the durable timeline. Cache data never crosses a card/size boundary.
public actor WidgetSnapshotReader {
    private let openRepository: @Sendable () async throws -> any PetalRepository
    private var cache: [String: WidgetSnapshot] = [:]

    public init(openRepository: @escaping @Sendable () async throws -> any PetalRepository) {
        self.openRepository = openRepository
    }

    public func snapshot(cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) async -> WidgetSnapshot {
        let key = cardID.rawValue.uuidString + (size == .medium ? ".medium" : ".large")
        do {
            let repository = try await openRepository()
            let value = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: cardID, size: size, now: now, calendar: calendar)
            if cache.count >= 32 { cache.removeAll() }
            cache[key] = value
            return value
        } catch {
            // A time-zone/calendar change can also make a completion belong to yesterday.
            let nextRefresh = calendar.dateInterval(of: .day, for: now)!.end
            let cached = cache[key].flatMap { now < $0.nextRefresh && $0.nextRefresh == nextRefresh ? $0 : nil }
            return WidgetSnapshot(cardID: cardID, title: cached?.title ?? "", visibleLines: cached?.visibleLines ?? [],
                hiddenCount: cached?.hiddenCount ?? 0, cardState: .persistenceError, syncBadge: cached?.syncBadge,
                nextRefresh: nextRefresh)
        }
    }
}
