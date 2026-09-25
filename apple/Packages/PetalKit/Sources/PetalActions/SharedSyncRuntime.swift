import Foundation
import PetalCore
import PetalPersistence
import PetalNotifications
import PetalSync

public struct SharedSyncRuntime: Sendable {
    public let sync: CloudSyncCoordinator
    public let lifecycle: AppLifecycleCoordinator
    public let reminders: ReminderCoordinator
    public let reset: ResetGenerationCoordinator
    public init(repository: any PetalSyncRepository, scheduler: any ReminderScheduling, transport: any CloudTransport,
                refreshStore: @escaping @Sendable () async throws -> Void = {},
                reloadWidgets: @escaping @Sendable () async -> Void) {
        let lifecycle = AppLifecycleCoordinator(repository: repository, scheduler: scheduler,
            refreshStore: refreshStore, reloadWidgets: reloadWidgets)
        let sync = CloudSyncCoordinator(repository: repository, transport: transport,
            afterInbound: { try await lifecycle.handle(.inboundSyncCompleted) },
            afterReset: { try await lifecycle.handle(.resetCompleted) })
        self.lifecycle = lifecycle; self.sync = sync
        reminders = ReminderCoordinator(repository: repository, scheduler: scheduler, reloadWidgets: reloadWidgets,
            requestSync: { _ = await sync.request(reason: .localMutation) })
        reset = ResetGenerationCoordinator(repository: repository,
            afterCommit: { try await lifecycle.handle(.resetCompleted) },
            requestSync: { _ = await sync.request(reason: .localMutation) })
    }
}

/// Local completion returns without waiting for network I/O. Pending work is
/// durable if the OS terminates the extension before its sync task finishes.
public struct SyncingWidgetTodoAction: WidgetTodoAction {
    private let openRepository: @Sendable () throws -> any PetalSyncRepository
    private let containerIdentifier: String
    private let reloadWidgets: @Sendable () async -> Void
    public init(openRepository: @escaping @Sendable () throws -> any PetalSyncRepository,
                containerIdentifier: String, reloadWidgets: @escaping @Sendable () async -> Void) {
        self.openRepository = openRepository; self.containerIdentifier = containerIdentifier; self.reloadWidgets = reloadWidgets
    }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        let runtime = SharedSyncRuntime(repository: try openRepository(),
            scheduler: UserNotificationScheduler(center: SystemNotificationCenter(), soundEnabled: { ReminderSoundPreference.isEnabled }),
            transport: CKSyncTransport(containerIdentifier: containerIdentifier), reloadWidgets: reloadWidgets)
        try await runtime.reminders.setCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
    }
}
