import Foundation
import PetalCore
import PetalPersistence
import PetalNotifications
import PetalActions
import Observation
import WidgetKit

struct AppEnvironment {
    let repository: any PetalSyncRepository & PetalTransferRepository
    var onboardingPending = false
    var completeOnboarding: () async throws -> Void = {}
    static var isTestRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func make() async throws -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        let testing = isTestRun
        let store: PetalStore
        if testing {
            store = try ModelContainerFactory.makeInMemory()
        } else {
            let groupID = Bundle.main.object(forInfoDictionaryKey: "PetalAppGroupIdentifier") as? String
            store = try ModelContainerFactory.makeShared(appGroupID: groupID ?? "")
        }
        let setup = SwiftDataPetalRepository(container: store)
        let onboardingPending: Bool
        if !testing || arguments.contains("-ui-onboarding") {
            onboardingPending = try await setup.bootstrapOnboarding(seed: OnboardingSeed(
                inbox: String(localized: "ui.inbox.94835e"), title: String(localized: "ui.welcome_to_petal.830c7d"), todos: [
                    String(localized: "ui.add_a_widget.f49140"), String(localized: "ui.complete_a_todo.e12126"), String(localized: "ui.create_a_card.345ca6")]), now: .now)
        } else { onboardingPending = false }
        try await setup.bootstrap(now: .now)
        if testing { try await setup.setSyncEnabled(false) }
        if testing && arguments.contains("-ui-sample-cards") {
            let active = try await setup.createCard(title: "Active sample", now: .now)
            _ = try await setup.addLine(NewLineDraft(cardID: active.id, kind: .todo, text: "shared todo"), now: .now)
            if arguments.contains("-ui-extra-active-candidate") {
                _ = try await setup.createCard(title: "Other active sample", now: .now)
            }
            let archived = try await setup.createCard(title: "Archived sample", now: .now)
            _ = try await setup.addLine(NewLineDraft(cardID: archived.id, kind: .text, text: "shared note"), now: .now)
            try await setup.moveCard(archived.id, to: .archived, replacementInbox: nil, now: .now)
        }
        if testing && arguments.contains("-ui-fail-next-save") {
            return AppEnvironment(repository: SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave))
        }
        return AppEnvironment(repository: setup, onboardingPending: onboardingPending,
            completeOnboarding: { try await setup.completeOnboarding() })
    }
}

@MainActor @Observable
final class AppReminderRuntime {
    let coordinator: ReminderCoordinator
    private(set) var state: ReconcileResult?
    private(set) var actionFailed = false
    init(coordinator: ReminderCoordinator) { self.coordinator = coordinator }
    init(repository: any PetalRepository) {
        let center = SystemNotificationCenter()
        coordinator = ReminderCoordinator(repository: repository,
            scheduler: UserNotificationScheduler(center: center, soundEnabled: {
                ReminderSoundPreference.isEnabled
            }), reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }
    func start(broker: NotificationResponseBroker) async {
        await broker.install(coordinator) { [weak self] in
            await self?.recordActionFailure()
        }
        await reconcile(.launch)
    }
    private func recordActionFailure() { actionFailed = true }
    func reconcile(_ reason: ReminderReconcileReason) async {
        do { state = try await coordinator.reconcile(reason) }
        catch { state = .schedulingFailed }
    }
}

/// Thin MainActor adapter; shared ordering remains in PetalActions.
@MainActor final class AppStoreRefreshAdapter {
    weak var router: AppRouter?
    func refresh() async { await router?.syncDidCommit() }
}
