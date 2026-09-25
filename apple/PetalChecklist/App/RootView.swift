import AppKit
import SwiftUI
import PetalCore
import PetalPersistence
import PetalNotifications
import PetalActions
import PetalSync
import WidgetKit
import PetalImportExport
import PetalDesignSystem

struct RootView: View {
    let capture: QuickCaptureAppController
    let notificationBroker: NotificationResponseBroker
    let terminationCoordinator: ApplicationTerminationCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var router: AppRouter?
    @State private var startupError: String?
    @State private var pendingInboxMove: PendingInboxMove?
    @State private var recordingShortcut = false
    @State private var reminders: AppReminderRuntime?
    @State private var commitRuntime: AppRepositoryCommitRuntime?
    @State private var syncSettings: SyncSettingsModel?
    @State private var dataTransfer: DataTransferModel?
    @State private var resetModel: ResetSettingsModel?
    @State private var onboardingPending = false
    @State private var finishOnboarding: () async throws -> Void = {}
    @State private var diagnostics: Diagnostics?
    @AppStorage("appearance.theme") private var theme = "cream"
    @AppStorage("appearance.typeface") private var typeface = "standard"
    @AppStorage("notificationSoundEnabled", store: ReminderSoundPreference.defaults) private var notificationSoundEnabled = false

    private struct PendingInboxMove {
        let cardID: CardID
        let status: CardStatus
        let candidates: [Card]
    }

    var body: some View {
        Group {
            if let router {
                VStack(spacing: 0) {
                    if reminders?.state == .schedulingFailed || reminders?.actionFailed == true {
                        Text("ui.reminder_scheduling_failed_open_the_reminder_and_save_a.cb2cc5")
                            .foregroundStyle(.red).padding(8)
                    }
                    if let error = router.errorMessage {
                        HStack {
                            Text(error)
                                .accessibilityLabel(Text(error))
                            Button("ui.retry.942087") { Task { await router.retryError() } }
                                .accessibilityIdentifier("app.retry")
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.red.opacity(0.12))
                        .accessibilityIdentifier("app.error")
                    }
                    NavigationSplitView {
                    List {
                        ForEach(LibraryScope.allCases) { scope in
                            Button { Task { await router.show(scope) } } label: {
                                Label(scopeName(scope), systemImage: icon(scope))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("scope.\(scope.rawValue)")
                        }
                    }
                    .navigationTitle("ui.petal_checklist.d92314")
                    .frame(minWidth: 160)
                    } content: {
                    CardLibraryView(model: router.library, selectedCardID: router.selectedCardID,
                                    onSelect: { id in Task { await router.select(id) } },
                                    onCreate: { Task { await router.createCard() } },
                                    onRestore: { id in Task { await router.restore(id) } })
                        .frame(minWidth: 220)
                    } detail: {
                    if router.scope == .settings {
                        ScrollView { VStack(alignment: .leading, spacing: 16) {
                            Text("ui.settings.74a883").font(.title)
                            Text("ui.local_cards_are_available_offline.f1e926")
                            Picker("ui.theme.efb52e", selection: $theme) {
                                Text("ui.cream.d5398b").tag("cream"); Text("ui.mint.ced97c").tag("mint"); Text("ui.sakura.95c0d6").tag("sakura")
                                Text("ui.sky.b72804").tag("sky"); Text("ui.paper.35045e").tag("paper")
                            }
                            Picker("ui.typeface.3a8c10", selection: $typeface) {
                                Text("ui.system.6725e7").tag("standard"); Text("ui.rounded.0a62cd").tag("rounded"); Text("ui.serif.1b5e74").tag("serif")
                            }
                            if let syncSettings {
                                SyncSettingsView(model: syncSettings, resetModel: resetModel) { id in
                                    Task {
                                        await router.show(.allCards)
                                        await router.select(id)
                                    }
                                }
                            }
                            if let dataTransfer { DataTransferView(model: dataTransfer) }
                            SupportSettingsView()
                            DiagnosticsExportView()
                            Toggle("ui.notification_sound.4478aa", isOn: $notificationSoundEnabled)
                                .onChange(of: notificationSoundEnabled) { _, _ in Task { await reminders?.reconcile(.localMutation) } }
                            Picker("ui.quick_capture_shortcut.6aa8d7", selection: Binding(
                                get: { capture.hotKey.selection },
                                set: { capture.hotKey.configure($0) }
                            )) {
                                ForEach(HotKeyChoice.allCases.contains(capture.hotKey.selection)
                                        ? HotKeyChoice.allCases
                                        : HotKeyChoice.allCases + [capture.hotKey.selection]) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .accessibilityIdentifier("settings.quickCaptureShortcut")
                            .disabled(recordingShortcut)
                            if recordingShortcut {
                                Text("ui.press_a_shortcut_with_command_option_or_control.3121f1")
                                HotKeyRecorderView(onCapture: { choice in
                                    capture.hotKey.configure(choice)
                                    recordingShortcut = false
                                }, onCancel: {
                                    capture.hotKey.cancelRecording()
                                    recordingShortcut = false
                                })
                                .frame(width: 250, height: 28)
                                Button("ui.cancel_recording.36bf97") {
                                    capture.hotKey.cancelRecording()
                                    recordingShortcut = false
                                }
                            } else {
                                Button("ui.record_shortcut.29eed5") {
                                    capture.hotKey.beginRecording()
                                    recordingShortcut = true
                                }
                                .accessibilityIdentifier("settings.recordShortcut")
                            }
                            if let error = capture.hotKey.errorMessage {
                                Text(error).foregroundStyle(.red)
                                    .accessibilityIdentifier("settings.hotKeyError")
                            }
                        }
                        .padding() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .onDisappear {
                            if recordingShortcut {
                                capture.hotKey.cancelRecording()
                                recordingShortcut = false
                            }
                        }
                    } else if let editor = router.editor {
                        CardEditorView(model: editor,
                                       onArchive: { Task { await moveSelected(to: .archived) } },
                                       onTrash: { Task { await moveSelected(to: .trashed) } },
                                       onRestore: { Task { await router.restore(editor.cardID) } })
                            .disabled(router.isTransitioning)
                    } else {
                        ContentUnavailableView("ui.select_a_card.e35278", systemImage: "checklist")
                    }
                    }
                }
                .background(WindowCloseGuard(flush: { await router.prepareClose() },
                                             closeRequestDidEnd: { router.closeRequestDidEnd() }))
                .confirmationDialog("ui.choose_new_inbox.bba42b", isPresented: Binding(
                    get: { pendingInboxMove != nil },
                    set: { if !$0 { pendingInboxMove = nil } }
                ), titleVisibility: .visible) {
                    if let pendingInboxMove {
                        ForEach(pendingInboxMove.candidates) { card in
                            Button(card.title) {
                                guard router.selectedCardID == pendingInboxMove.cardID else { return }
                                Task { await router.moveSelected(to: pendingInboxMove.status, replacementInbox: card.id) }
                                self.pendingInboxMove = nil
                            }
                        }
                    }
                }
            } else if let startupError {
                ContentUnavailableView("ui.unable_to_open_cards.a94fd5", systemImage: "exclamationmark.triangle",
                                       description: Text(startupError))
            } else {
                ProgressView("ui.opening_cards.33b61d")
            }
        }
        .sheet(isPresented: $onboardingPending) {
            OnboardingView { try await finishOnboarding(); onboardingPending = false }
        }
        .task {
            guard router == nil else { return }
            if !AppEnvironment.isTestRun {
                diagnostics = try? Diagnostics.local()
                try? await diagnostics?.prune()
            }
            do {
                let opened = try await AppEnvironment.make()
                onboardingPending = opened.onboardingPending
                finishOnboarding = opened.completeOnboarding
                let model = CardLibraryModel(repository: opened.repository)
                try await model.show(.inbox)
                let refresh = AppStoreRefreshAdapter()
                let shared = SharedSyncRuntime(repository: opened.repository,
                    scheduler: UserNotificationScheduler(center: SystemNotificationCenter(), soundEnabled: { ReminderSoundPreference.isEnabled }),
                    transport: CKSyncTransport(containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "PetalCloudContainerIdentifier") as? String ?? "iCloud.com.petalchecklist"),
                    refreshStore: { await refresh.refresh() }, reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
                let runtime = AppReminderRuntime(coordinator: shared.reminders)
                reminders = runtime
                let navigation = AppRouter(repository: opened.repository, library: model, reminders: runtime.coordinator)
                let repositoryCommits = AppRepositoryCommitRuntime(
                    router: navigation,
                    reconcileReminders: { await runtime.reconcile(.localMutation) },
                    reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }
                )
                repositoryCommits.startCrossProcessObservation()
                commitRuntime = repositoryCommits
                terminationCoordinator.prepare = { [weak navigation] in
                    await navigation?.prepareClose() ?? true
                }
                refresh.router = navigation
                let settings = SyncSettingsModel(repository: opened.repository, coordinator: shared.sync)
                syncSettings = settings
                await settings.startObserving()
                router = navigation
                resetModel = ResetSettingsModel(productName: String(localized: "ui.petal_checklist.d92314"), defaults: .standard,
                    reset: {
                        guard await navigation.prepareClose() else { throw EditorError.pendingSaveFailed }
                        defer { navigation.closeRequestDidEnd() }
                        return try await shared.reset.reset(now: .now).sideEffectsSucceeded
                    }, retryEffects: {
                        try await opened.repository.finishResetCleanup()
                        try await shared.lifecycle.handle(.resetCompleted)
                        await settings.sync(.userRequested)
                    }, onFinished: {
                        settings.isResetRequested = false
                        await navigation.show(.inbox)
                        if let inbox = navigation.library.cards.first(where: \.isInbox) { await navigation.select(inbox.id) }
                    })
                dataTransfer = DataTransferModel(repository: opened.repository,
                    settings: { TransferSettings(notificationSoundEnabled: ReminderSoundPreference.isEnabled) },
                    applySettings: { ReminderSoundPreference.defaults?.set($0.notificationSoundEnabled, forKey: "notificationSoundEnabled") },
                    prepare: { await navigation.prepareClose() },
                    finished: { navigation.closeRequestDidEnd(); await navigation.syncDidCommit(); await runtime.reconcile(.localMutation) })
                if let inbox = model.cards.first { await navigation.select(inbox.id) }
                capture.configure(repository: opened.repository) { [weak navigation] id in
                    await navigation?.captureDidCommit(to: id)
                }
                let links = DeepLinkHandler(router: navigation) { try capture.presentFromDeepLink(targetCardID: $0) }
                await PetalNavigationRequests.shared.install { url in
                    openWindow(id: "main")
                    await links.handle(url)
                }
                capture.openFromLaunchArguments()
                await runtime.start(broker: notificationBroker)
                await settings.sync(.launch)
            } catch {
                startupError = PetalErrorCopy.message(error)
                try? await diagnostics?.record(.current(subsystem: .storage, errorCode: .openFailed, syncState: .unknown))
            }
        }
        .onChange(of: dataTransfer?.failed) { _, failed in
            if failed == true { Task { try? await diagnostics?.record(.current(subsystem: .transfer, errorCode: .saveFailed, syncState: .unknown)) } }
        }
        .onChange(of: syncSettings?.operationFailed) { _, failed in
            if failed == true { Task { try? await diagnostics?.record(.current(subsystem: .sync, errorCode: .unavailable, syncState: .unknown)) } }
        }
        .onChange(of: reminders?.state) { _, state in
            if state == .schedulingFailed { Task { try? await diagnostics?.record(.current(subsystem: .notifications, errorCode: .unavailable, syncState: .unknown)) } }
        }
        .onOpenURL { url in Task { await PetalNavigationRequests.shared.open(url) } }
        .onReceive(NotificationCenter.default.publisher(for: .petalCloudPushReceived).receive(on: DispatchQueue.main)) { _ in
            Task { await syncSettings?.sync(.push) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .petalRepositoryDidCommit).receive(on: DispatchQueue.main)) { _ in
            Task {
                await commitRuntime?.handleCommit()
                await syncSettings?.sync(.localMutation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                router?.refreshTemporalState()
                WidgetCenter.shared.reloadAllTimelines()
                await reminders?.reconcile(.foreground)
                await syncSettings?.sync(.foreground)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task {
                router?.refreshTemporalState()
                WidgetCenter.shared.reloadAllTimelines()
                await reminders?.reconcile(.dateChange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            Task {
                router?.refreshTemporalState()
                WidgetCenter.shared.reloadAllTimelines()
                await reminders?.reconcile(.dateChange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task {
                router?.refreshTemporalState()
                WidgetCenter.shared.reloadAllTimelines()
                await reminders?.reconcile(.timeZoneChange)
            }
        }
    }

    private func icon(_ scope: LibraryScope) -> String {
        switch scope {
        case .inbox: "tray"
        case .allCards: "rectangle.stack"
        case .archive: "archivebox"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }

    private func moveSelected(to status: CardStatus) async {
        guard let router, let id = router.selectedCardID else { return }
        do {
            let candidates = try await router.library.replacementCandidates(for: id)
            guard router.selectedCardID == id else { return }
            if Self.shouldPromptForInboxReplacement(candidates: candidates) {
                pendingInboxMove = PendingInboxMove(cardID: id, status: status, candidates: candidates)
            } else {
                await router.moveSelected(to: status, replacementInbox: candidates.first?.id)
            }
        } catch {
            router.present(error) { await moveSelected(to: status) }
        }
    }

    static func shouldPromptForInboxReplacement(candidates: [Card]) -> Bool {
        !candidates.isEmpty
    }
}

/// Intercepts the only document window's close while its editor commits pending drafts.
private struct WindowCloseGuard: NSViewRepresentable {
    let flush: @MainActor () async -> Bool
    let closeRequestDidEnd: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.flush = flush
        context.coordinator.closeRequestDidEnd = closeRequestDidEnd
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var flush: (@MainActor () async -> Bool)?
        var closeRequestDidEnd: (@MainActor () -> Void)?
        private weak var window: NSWindow?
        private var previousDelegate: (any NSWindowDelegate)?
        private var canClose = false

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self { window?.delegate = previousDelegate }
            window = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if canClose {
                let allowed = previousDelegate?.windowShouldClose?(sender) ?? true
                if !allowed { resetCloseRequest() }
                return allowed
            }
            Task { @MainActor in
                guard await flush?() ?? true else { return }
                canClose = true
                sender.performClose(nil)
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
            resetCloseRequest()
        }

        private func resetCloseRequest() {
            canClose = false
            closeRequestDidEnd?()
        }
    }
}
