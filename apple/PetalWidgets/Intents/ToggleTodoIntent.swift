import AppIntents
import Foundation
import WidgetKit
import PetalCore
import PetalPersistence
import PetalActions
import PetalNotifications

protocol WidgetReloading: Sendable {
    func reload(kind: String) async
}

struct SystemWidgetReloader: WidgetReloading {
    func reload(kind: String) async { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
}

enum WidgetIntentOutcome: Equatable {
    case success, contentUnavailable, saveFailed
    var dialog: IntentDialog {
        switch self {
        case .success: IntentDialog(LocalizedStringResource("Todo updated", table: "Widgets"))
        case .contentUnavailable: IntentDialog(LocalizedStringResource("This item is unavailable. Open Petal to review the card.", table: "Widgets"))
        case .saveFailed: IntentDialog(LocalizedStringResource("Unable to save. Please try again in Petal.", table: "Widgets"))
        }
    }
}

/// UUID identity never depends on a localized label or on stale timeline text.
struct TodoLineEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Todo", table: "Widgets"))
    static let defaultQuery = TodoLineQuery()
    let id: UUID
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource("Todo", table: "Widgets")) }
}

struct TodoLineQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [TodoLineEntity] {
        identifiers.map { TodoLineEntity(id: $0) }
    }
    func suggestedEntities() async throws -> [TodoLineEntity] { [] }
}

struct ToggleTodoIntent: AppIntent {
    static let title = LocalizedStringResource("Change Todo Completion", table: "Widgets")
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("Todo", table: "Widgets")) var line: TodoLineEntity
    @Parameter(title: LocalizedStringResource("Completed", table: "Widgets")) var completed: Bool

    init() {}
    init(lineID: LineID, completed: Bool) {
        self.line = TodoLineEntity(id: lineID.rawValue)
        self.completed = completed
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let action = ReminderWidgetTodoAction(openRepository: { try WidgetStore.open() })
        let outcome = await perform(action: action,
            reloader: SystemWidgetReloader(), clock: { .now })
        return .result(dialog: outcome.dialog)
    }

    func perform(action: any WidgetTodoAction, reloader: any WidgetReloading,
                 clock: @escaping @Sendable () -> Date, calendar: Calendar = .current) async -> WidgetIntentOutcome {
        let work = await enqueue(action: action, reloader: reloader, clock: clock, calendar: calendar)
        return await work.value
    }

    func enqueue(action: any WidgetTodoAction, reloader: any WidgetReloading,
                 clock: @escaping @Sendable () -> Date, calendar: Calendar = .current,
                 coordinator: WidgetLineActionCoordinator = .shared) async -> Task<WidgetIntentOutcome, Never> {
        await coordinator.enqueue(lineID: LineID(rawValue: line.id)) {
            await performOrdered(action: action, reloader: reloader, clock: clock, calendar: calendar)
        }
    }

    private func performOrdered(action: any WidgetTodoAction, reloader: any WidgetReloading,
                 clock: @Sendable () -> Date, calendar: Calendar) async -> WidgetIntentOutcome {
        let outcome: WidgetIntentOutcome
        do {
            try await action.setCompleted(lineID: LineID(rawValue: line.id), completed: completed, now: clock(), calendar: calendar)
            outcome = .success
        } catch RepositoryError.lineUnavailable { outcome = .contentUnavailable
        } catch RepositoryError.cardUnavailable { outcome = .contentUnavailable
        } catch { outcome = .saveFailed }
        await reloader.reload(kind: ChecklistWidget.kind)
        return outcome
    }
}
