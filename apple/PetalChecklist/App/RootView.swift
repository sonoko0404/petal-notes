import AppKit
import SwiftUI
import PetalCore

struct RootView: View {
    @State private var router = AppRouter()
    @State private var environment: AppEnvironment?
    @State private var library: CardLibraryModel?
    @State private var editor: CardEditorModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let library, environment != nil {
                NavigationSplitView {
                    List {
                        ForEach(LibraryScope.allCases) { scope in
                            Button { Task { await show(scope) } } label: {
                                Label(scopeName(scope), systemImage: icon(scope))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("scope.\(scope.rawValue)")
                        }
                    }
                    .navigationTitle("Petal Checklist")
                    .frame(minWidth: 160)
                } content: {
                    CardLibraryView(model: library, selectedCardID: router.selectedCardID,
                                    onSelect: { id in Task { await select(id) } },
                                    onCreate: { Task { await createCard() } },
                                    onRestore: { id in Task { await restore(id) } })
                        .frame(minWidth: 220)
                } detail: {
                    if router.scope == .settings {
                        VStack(alignment: .leading) {
                            Text("Settings").font(.title)
                            Text("Local cards are available offline.")
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let editor {
                        CardEditorView(model: editor,
                                       onArchive: { Task { await moveSelected(to: .archived) } },
                                       onTrash: { Task { await moveSelected(to: .trashed) } })
                    } else {
                        ContentUnavailableView("Select a Card", systemImage: "checklist")
                    }
                }
                .background(WindowCloseGuard { await editor?.flushPending() ?? true })
            } else if let startupError {
                ContentUnavailableView("Unable to Open Cards", systemImage: "exclamationmark.triangle",
                                       description: Text(startupError))
            } else {
                ProgressView("Opening Cards")
            }
        }
        .task {
            guard library == nil else { return }
            do {
                let opened = try await AppEnvironment.make()
                let model = CardLibraryModel(repository: opened.repository)
                try await model.show(.inbox)
                environment = opened
                library = model
                if let inbox = model.cards.first { await select(inbox.id) }
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

    private func show(_ scope: LibraryScope) async {
        if let editor, !(await editor.flushPending()) { return }
        do {
            try await library?.show(scope)
            router.scope = scope
            router.selectedCardID = nil
            editor = nil
        } catch { library?.errorMessage = error.localizedDescription }
    }

    private func select(_ id: CardID) async {
        if let editor, !(await editor.flushPending()) { return }
        guard let environment else { return }
        let next = CardEditorModel(cardID: id, repository: environment.repository)
        do {
            try await next.load()
            editor = next
            router.selectedCardID = id
        } catch { library?.errorMessage = error.localizedDescription }
    }

    private func createCard() async {
        if let editor, !(await editor.flushPending()) { return }
        do {
            guard let card = try await library?.createCard(title: String(localized: "Untitled Card")) else { return }
            router.scope = .allCards
            await select(card.id)
        } catch { library?.errorMessage = error.localizedDescription }
    }

    private func moveSelected(to status: CardStatus) async {
        guard let id = router.selectedCardID, let library else { return }
        if let editor, !(await editor.flushPending()) { return }
        do {
            try await library.move(id, to: status)
            router.selectedCardID = nil
            editor = nil
        } catch { library.errorMessage = error.localizedDescription }
    }

    private func restore(_ id: CardID) async {
        do { try await library?.restore(id) }
        catch { library?.errorMessage = error.localizedDescription }
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
