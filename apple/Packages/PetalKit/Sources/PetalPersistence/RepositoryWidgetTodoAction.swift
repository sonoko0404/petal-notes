import Foundation
import PetalCore

public struct RepositoryWidgetTodoAction: WidgetTodoAction {
    private let openRepository: @Sendable () throws -> any PetalRepository
    public init(repository: any PetalRepository) { openRepository = { repository } }
    public init(openRepository: @escaping @Sendable () throws -> any PetalRepository) {
        self.openRepository = openRepository
    }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        try await openRepository().setWidgetCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
    }
}
