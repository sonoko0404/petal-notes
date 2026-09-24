import Foundation
import PetalCore

public struct WidgetSnapshotBuilder: Sendable {
    private let repository: any PetalRepository

    public init(repository: any PetalRepository) { self.repository = repository }

    public func snapshot(cardID: CardID, size: WidgetDisplaySize, now: Date, calendar: Calendar) async throws -> WidgetSnapshot {
        let card = try await repository.card(id: cardID)
        let nextRefresh = calendar.dateInterval(of: .day, for: now)!.end
        guard let card, card.status == .active else {
            return WidgetSnapshot(cardID: cardID, title: card?.title ?? "", visibleLines: [], hiddenCount: 0,
                cardState: card?.status == .archived ? .archived : card?.status == .trashed ? .trashed : .unavailable,
                nextRefresh: nextRefresh)
        }
        let ordered = try await repository.lines(cardID: cardID).filter { $0.deletedAt == nil }.sorted {
            $0.sortIndex == $1.sortIndex ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.sortIndex < $1.sortIndex
        }.map { line in
            var line = line
            if line.kind == .todo, case .daily = line.reminder?.rule, line.isCompleted,
               let completedAt = line.completedAt, !calendar.isDate(completedAt, inSameDayAs: now), completedAt < now {
                line.isCompleted = false
                line.completedAt = nil
            }
            return line
        }
        let incomplete = ordered.filter { $0.kind == .text || !$0.isCompleted }
        let completed = ordered.filter {
            $0.kind == .todo && $0.isCompleted && $0.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        let lines = incomplete + completed
        let capacity = size == .medium ? 5 : 10
        return WidgetSnapshot(cardID: cardID, title: card.title, visibleLines: lines.prefix(capacity).map {
            WidgetLine(id: $0.id, kind: $0.kind, text: $0.text, isCompleted: $0.kind == .todo && $0.isCompleted)
        }, hiddenCount: max(0, lines.count - capacity), cardState: lines.isEmpty ? .empty : .normal,
           nextRefresh: nextRefresh)
    }
}
