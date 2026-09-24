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
        case .success: IntentDialog(LocalizedStringResource("ui.todo_updated.d1612f", table: "Widgets"))
        case .contentUnavailable: IntentDialog(LocalizedStringResource("ui.this_item_is_unavailable_open_petal_to_review_the_card.d98a23", table: "Widgets"))
        case .saveFailed: IntentDialog(LocalizedStringResource("ui.unable_to_save_please_try_again_in_petal.1e4a38", table: "Widgets"))
        }
    }
}

/// UUID identity never depends on a localized label or on stale timeline text.
struct TodoLineEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("ui.todo.4ff402", table: "Widgets"))
    static let defaultQuery = TodoLineQuery()
    let id: UUID
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource("ui.todo.4ff402", table: "Widgets")) }
}

struct TodoLineQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [TodoLineEntity] {
        identifiers.map { TodoLineEntity(id: $0) }
    }
    func suggestedEntities() async throws -> [TodoLineEntity] { [] }
}

struct ToggleTodoIntent: AppIntent {
    static let title = LocalizedStringResource("ui.change_todo_completion.b0f064", table: "Widgets")
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("ui.todo.4ff402", table: "Widgets")) var line: TodoLineEntity
    @Parameter(title: LocalizedStringResource("ui.completed.22a970", table: "Widgets")) var completed: Bool

    init() {}
    init(lineID: LineID, completed: Bool) {
        self.line = TodoLineEntity(id: lineID.rawValue)
        self.completed = completed
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let action = SyncingWidgetTodoAction(openRepository: { try WidgetStore.open() },
            containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "PetalCloudContainerIdentifier") as? String ?? "iCloud.com.petalchecklist",
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
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
