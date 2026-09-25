import Foundation

/// Arrival order is reservation order in this process. Each line has one FIFO
/// action chain, including any awaits before mutation and post-commit work.
/// Different lines remain independent; repository transactions still provide
/// the durable cross-process store lock and stale-data checks.
public actor WidgetLineActionCoordinator {
    public static let shared = WidgetLineActionCoordinator()
    private struct Tail {
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var tails: [LineID: Tail] = [:]
    public init() {}

    public func enqueue<Result: Sendable>(lineID: LineID,
        operation: @escaping @Sendable () async -> Result) -> Task<Result, Never> {
        let preceding = tails[lineID]?.task
        let generation = UUID()
        let work = Task {
            await preceding?.value
            return await operation()
        }
        let tail = Task {
            _ = await work.value
            if tails[lineID]?.generation == generation { tails.removeValue(forKey: lineID) }
        }
        tails[lineID] = Tail(generation: generation, task: tail)
        return work
    }
}
