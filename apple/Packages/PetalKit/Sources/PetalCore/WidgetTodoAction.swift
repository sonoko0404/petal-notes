import Foundation

/// Shared orchestration boundary. Task 9 can reconcile notifications and request
/// sync after the local commit without introducing an App dependency into widgets.
public protocol WidgetTodoAction: Sendable {
    func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws
}
