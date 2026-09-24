import Observation
import PetalCore
import PetalPersistence

enum LibraryScope: String, CaseIterable, Identifiable {
    case inbox, allCards, archive, trash, settings

    var id: Self { self }
}

@MainActor @Observable
final class AppRouter {
    private let repository: any PetalRepository
    let library: CardLibraryModel
    private(set) var scope: LibraryScope = .inbox
    private(set) var selectedCardID: CardID?
    private(set) var editor: CardEditorModel?
    private(set) var isTransitioning = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var editors: [CardID: CardEditorModel] = [:]
    @ObservationIgnored private var transitionTail: Task<Void, Never>?
    @ObservationIgnored private var latestRequest = 0
    @ObservationIgnored private var pendingTransitions = 0
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var retryAction: (@MainActor () async -> Void)?

    init(repository: any PetalRepository, library: CardLibraryModel) {
        self.repository = repository
        self.library = library
    }

    private func isCurrent(_ request: Int) -> Bool { request == latestRequest && !closing }

    private func transition(_ operation: @escaping @MainActor (Int) async throws -> Void,
                            retry: @escaping @MainActor () async -> Void) async {
        guard !closing else { return }
        latestRequest += 1
        let request = latestRequest
        pendingTransitions += 1
        isTransitioning = true
        editor?.setTransitionLocked(true)
        let preceding = transitionTail
        let work = Task { @MainActor [self] in
            await preceding?.value
            defer {
                pendingTransitions -= 1
                isTransitioning = pendingTransitions > 0 || closing
                if !isTransitioning { for model in editors.values { model.setTransitionLocked(false) } }
            }
            guard isCurrent(request) else { return }
            retryAction = nil
            do {
                try await operation(request)
                guard isCurrent(request) else { return }
                errorMessage = nil
                retryAction = nil
            } catch {
                guard isCurrent(request) else { return }
                errorMessage = error.localizedDescription
                retryAction = retryAction ?? retry
            }
        }
        transitionTail = work
        await work.value
    }

    private func flushEditor() async throws {
        if let editor, !(await editor.flushPending()) { throw EditorError.pendingSaveFailed }
    }

    func select(_ id: CardID) async {
        await transition({ [self] request in
            try await flushEditor()
            guard isCurrent(request) else { return }
            let next = editors[id] ?? CardEditorModel(cardID: id, repository: repository)
            try await next.load()
            guard isCurrent(request) else { return }
            editors[id] = next
            next.setTransitionLocked(true)
            editor = next
            selectedCardID = id
        }, retry: { [weak self] in await self?.select(id) })
    }

    func show(_ destination: LibraryScope) async {
        await transition({ [self] request in
            try await flushEditor()
            guard isCurrent(request) else { return }
            try await library.show(destination)
            guard isCurrent(request) else { return }
            scope = destination
            selectedCardID = nil
            editor = nil
        }, retry: { [weak self] in await self?.show(destination) })
    }

    func createCard() async {
        await transition({ [self] request in
            try await flushEditor()
            guard isCurrent(request) else { return }
            let card = try await library.createCard(title: String(localized: "Untitled Card"))
            retryAction = { [weak self] in await self?.select(card.id) }
            let next = CardEditorModel(cardID: card.id, repository: repository)
            try await next.load()
            guard isCurrent(request) else { return }
            editors[card.id] = next
            next.setTransitionLocked(true)
            scope = .allCards
            editor = next
            selectedCardID = card.id
        }, retry: { [weak self] in await self?.createCard() })
    }

    func moveSelected(to status: CardStatus, replacementInbox: CardID? = nil) async {
        guard let id = selectedCardID else { return }
        await transition({ [self] request in
            try await flushEditor()
            guard isCurrent(request) else { return }
            try await library.move(id, to: status, replacementInbox: replacementInbox)
            guard isCurrent(request) else { return }
            selectedCardID = nil
            editor = nil
        }, retry: { [weak self] in await self?.moveSelected(to: status, replacementInbox: replacementInbox) })
    }

    func restore(_ id: CardID) async {
        await transition({ [self] request in
            try await flushEditor()
            guard isCurrent(request) else { return }
            try await library.restore(id)
            if selectedCardID == id { try await editor?.load() }
        }, retry: { [weak self] in await self?.restore(id) })
    }

    func captureDidCommit(to id: CardID) async {
        await transition({ [self] request in
            if selectedCardID == id, let current = editor {
                try await flushEditor()
                guard isCurrent(request), selectedCardID == id, editor === current else { return }
                try await current.load()
            }
            try await library.refresh()
        }, retry: { [weak self] in await self?.captureDidCommit(to: id) })
    }

    func retryError() async {
        let retry = retryAction
        errorMessage = nil
        retryAction = nil
        await retry?()
    }

    func present(_ error: Error, retry: @escaping @MainActor () async -> Void) {
        errorMessage = error.localizedDescription
        retryAction = retry
    }

    func prepareClose() async -> Bool {
        guard !closing else { return false }
        closing = true
        isTransitioning = true
        editor?.setTransitionLocked(true)
        await transitionTail?.value
        let saved = await editor?.flushPending() ?? true
        if !saved {
            closing = false
            isTransitioning = false
            editor?.setTransitionLocked(false)
        }
        return saved
    }

    func closeRequestDidEnd() {
        closing = false
        isTransitioning = pendingTransitions > 0
        if !isTransitioning {
            for model in editors.values { model.setTransitionLocked(false) }
        }
    }
}
