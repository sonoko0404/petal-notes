import AppKit
import SwiftUI
import PetalCore
import PetalPersistence
import PetalNotifications
import PetalActions
import PetalSync
import WidgetKit
import PetalImportExport

struct RootView: View {
    let capture: QuickCaptureAppController
    let notificationBroker: NotificationResponseBroker
    @Environment(\.openWindow) private var openWindow
    @State private var router: AppRouter?
    @State private var startupError: String?
    @State private var pendingInboxMove: PendingInboxMove?
    @State private var recordingShortcut = false
    @State private var reminders: AppReminderRuntime?
    @State private var syncSettings: SyncSettingsModel?
    @State private var dataTransfer: DataTransferModel?
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
                        Text("Reminder scheduling failed. Open the reminder and save again to retry.")
                            .foregroundStyle(.red).padding(8)
                    }
                    if let error = router.errorMessage {
                        HStack {
                            Text(error)
                                .accessibilityLabel(Text(error))
                            Button("Retry") { Task { await router.retryError() } }
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
                    .navigationTitle("Petal Checklist")
                    .frame(minWidth: 160)
                    } content: {
                    CardLibraryView(model: router.library, selectedCardID: router.selectedCardID,
                                    onSelect: { id in Task { await router.select(id) } },
                                    onCreate: { Task { await router.createCard() } },
                                    onRestore: { id in Task { await router.restore(id) } })
                        .frame(minWidth: 220)
                    } detail: {
                    if router.scope == .settings {
                        VStack(alignment: .leading) {
                            Text("Settings").font(.title)
                            Text("Local cards are available offline.")
                            if let syncSettings { SyncSettingsView(model: syncSettings) }
                            if let dataTransfer { DataTransferView(model: dataTransfer) }
                            Toggle("Notification Sound", isOn: $notificationSoundEnabled)
                                .onChange(of: notificationSoundEnabled) { _, _ in Task { await reminders?.reconcile(.localMutation) } }
                            Picker("Quick Capture Shortcut", selection: Binding(
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
                                Text("Press a shortcut with Command, Option, or Control")
                                HotKeyRecorderView(onCapture: { choice in
                                    capture.hotKey.configure(choice)
                                    recordingShortcut = false
                                }, onCancel: {
                                    capture.hotKey.cancelRecording()
                                    recordingShortcut = false
                                })
                                .frame(width: 250, height: 28)
                                Button("Cancel Recording") {
                                    capture.hotKey.cancelRecording()
                                    recordingShortcut = false
                                }
                            } else {
                                Button("Record Shortcut") {
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
                        .padding()
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
                        ContentUnavailableView("Select a Card", systemImage: "checklist")
                    }
                    }
                }
                .background(WindowCloseGuard(flush: { await router.prepareClose() },
                                             closeRequestDidEnd: { router.closeRequestDidEnd() }))
                .confirmationDialog("Choose New Inbox", isPresented: Binding(
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
                ContentUnavailableView("Unable to Open Cards", systemImage: "exclamationmark.triangle",
                                       description: Text(startupError))
            } else {
                ProgressView("Opening Cards")
            }
        }
        .task {
            guard router == nil else { return }
            do {
                let opened = try await AppEnvironment.make()
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
                refresh.router = navigation
                let settings = SyncSettingsModel(repository: opened.repository, coordinator: shared.sync)
                syncSettings = settings
                await settings.startObserving()
                router = navigation
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
                startupError = error.localizedDescription
            }
        }
        .onOpenURL { url in Task { await PetalNavigationRequests.shared.open(url) } }
        .onReceive(NotificationCenter.default.publisher(for: .petalCloudPushReceived).receive(on: DispatchQueue.main)) { _ in
            Task { await syncSettings?.sync(.push) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .petalRepositoryDidCommit).receive(on: DispatchQueue.main)) { _ in
            Task { await reminders?.reconcile(.localMutation); await syncSettings?.sync(.localMutation) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reminders?.reconcile(.foreground); await syncSettings?.sync(.foreground) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await reminders?.reconcile(.dateChange) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            Task { await reminders?.reconcile(.dateChange) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await reminders?.reconcile(.timeZoneChange) }
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
