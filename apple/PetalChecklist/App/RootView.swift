import AppKit
import SwiftUI
import PetalCore

struct RootView: View {
    @State private var router: AppRouter?
    @State private var startupError: String?
    @State private var pendingInboxMove: PendingInboxMove?

    private struct PendingInboxMove {
        let cardID: CardID
        let status: CardStatus
        let candidates: [Card]
    }

    var body: some View {
        Group {
            if let router {
                VStack(spacing: 0) {
                    if let error = router.errorMessage {
                        HStack {
                            Text(error)
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
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .background(WindowCloseGuard { await router.prepareClose() })
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
                let navigation = AppRouter(repository: opened.repository, library: model)
                router = navigation
                if let inbox = model.cards.first { await navigation.select(inbox.id) }
            } catch {
                startupError = error.localizedDescription
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
            if candidates.count > 1 {
                pendingInboxMove = PendingInboxMove(cardID: id, status: status, candidates: candidates)
            } else {
                await router.moveSelected(to: status, replacementInbox: candidates.first?.id)
            }
        } catch {
            router.present(error) { await moveSelected(to: status) }
        }
    }
}

/// Intercepts the only document window's close while its editor commits pending drafts.
private struct WindowCloseGuard: NSViewRepresentable {
    let flush: @MainActor () async -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.flush = flush
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var flush: (@MainActor () async -> Bool)?
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
            if canClose { return previousDelegate?.windowShouldClose?(sender) ?? true }
            Task { @MainActor in
                guard await flush?() ?? true else { return }
                canClose = true
                sender.performClose(nil)
            }
            return false
        }
    }
}
