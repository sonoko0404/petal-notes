import Foundation
import PetalCore

public struct WidgetSnapshotBuilder: Sendable {
    private let repository: any PetalRepository

    public init(repository: any PetalRepository) { self.repository = repository }

    public func snapshot(cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) async throws -> WidgetSnapshot {
        let card = try await repository.card(id: cardID)
        let nextRefresh = calendar.dateInterval(of: .day, for: now)!.end
        let badge: WidgetSyncBadge?
        if let sync = repository as? any PetalSyncRepository,
           let status = try? await sync.widgetSyncStatus(), status.enabled,
           case .failed = status.state { badge = .failed }
        else { badge = nil }
        guard let card, card.status == .active else {
            return WidgetSnapshot(cardID: cardID, title: card?.title ?? "", visibleLines: [], hiddenCount: 0,
                cardState: card?.status == .archived ? .archived : card?.status == .trashed ? .trashed : .unavailable,
                syncBadge: badge, nextRefresh: nextRefresh)
        }
        let ordered = try await repository.lines(cardID: cardID).filter { $0.deletedAt == nil }.sorted {
            $0.sortIndex == $1.sortIndex ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.sortIndex < $1.sortIndex
        }.map { line in
            var line = line
            line.isCompleted = CompletionPolicy.isCompleted(line, now: now, calendar: calendar)
            return line
        }
        let incomplete = ordered.filter { $0.kind == .text || !$0.isCompleted }
        let completed = ordered.filter {
            $0.kind == .todo && $0.isCompleted && CompletionPolicy.isVisibleInWidget(completedAt: $0.completedAt, now: now, calendar: calendar)
        }
        let lines = incomplete + completed
        let capacity = size == .medium ? 5 : 10
        return WidgetSnapshot(cardID: cardID, title: card.title, visibleLines: lines.prefix(capacity).map {
            WidgetLine(id: $0.id, kind: $0.kind, text: $0.text, isCompleted: $0.kind == .todo && $0.isCompleted)
        }, hiddenCount: max(0, lines.count - capacity), cardState: lines.isEmpty ? .empty : .normal,
           syncBadge: badge, nextRefresh: nextRefresh)
    }
}
