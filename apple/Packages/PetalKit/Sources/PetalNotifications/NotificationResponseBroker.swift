import Foundation
import PetalCore

/// Launch-time queue stores UUIDs/actions only, never notification text. Services
/// attach after both persistence and navigation are ready. Overflow rejects the
/// newest response and is surfaced through the delegate's failure channel.
public actor NotificationResponseBroker: NotificationActionHandling {
    public enum Failure: Error { case queueFull }
    private struct Pending: Sendable {
        let action: NotificationAction
        let lineID: LineID
        let cardID: CardID
    }
    private let capacity: Int
    private var queue: [Pending] = []
    private var handler: (any NotificationActionHandling)?
    private var onFailure: (@Sendable () async -> Void)?
    private var draining = false
    private var failedBeforeReady = false
    public init(capacity: Int = 64) { precondition(capacity > 0); self.capacity = capacity }

    public func handle(_ action: NotificationAction, lineID: LineID, cardID: CardID) async throws {
        guard queue.count < capacity else { throw Failure.queueFull }
        queue.append(Pending(action: action, lineID: lineID, cardID: cardID))
        await drain()
    }
    public func install(_ handler: any NotificationActionHandling, onFailure: @escaping @Sendable () async -> Void) async {
        self.handler = handler
        self.onFailure = onFailure
        if failedBeforeReady { failedBeforeReady = false; await onFailure() }
        await drain()
    }
    public func recordFailure() async {
        if let onFailure { await onFailure() } else { failedBeforeReady = true }
    }
    private func drain() async {
        guard !draining, let handler else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let pending = queue.removeFirst()
            do { try await handler.handle(pending.action, lineID: pending.lineID, cardID: pending.cardID) }
            catch { await recordFailure() }
        }
    }
}
