import Foundation
import Observation
import PetalCore
import PetalPersistence

enum SaveState: Equatable {
    case saved
    case saving
    case failed(String)
}

enum EditorError: Error { case pendingSaveFailed, transitionInProgress }

@MainActor @Observable
final class CardEditorModel {
    let cardID: CardID
    private let repository: any PetalRepository
    private(set) var title = ""
    private(set) var lines: [CardLine] = []
    private(set) var status: CardStatus = .active
    var isReadOnly: Bool { status == .trashed }
    private(set) var newLineDraft = ""
    private(set) var isAddingLine = false
    private(set) var newLineError: String?
    private(set) var isTransitionLocked = false
    private(set) var unsavedText: [LineID: String] = [:]
    private(set) var unsavedTitle: String?
    private(set) var saveState: SaveState = .saved
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var activeSave: Task<Bool, Never>?
    @ObservationIgnored private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var newLineRevision = 0

    init(cardID: CardID, repository: any PetalRepository) {
        self.cardID = cardID
        self.repository = repository
    }

    func setTransitionLocked(_ locked: Bool) { isTransitionLocked = locked }

    func load() async throws {
        guard let card = try await repository.card(id: cardID) else { throw RepositoryError.cardUnavailable }
        title = card.title
        status = card.status
        lines = try await repository.lines(cardID: cardID)
    }

    func addLine(text: String) async throws {
        guard !isTransitionLocked else { throw EditorError.transitionInProgress }
        guard status != .trashed else { throw RepositoryError.cardUnavailable }
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        let line = try await repository.addLine(NewLineDraft(cardID: cardID, kind: .todo, text: text), now: .now)
        lines.append(line)
    }

    func convert(lineID: LineID, to kind: LineKind) async throws {
        guard !isTransitionLocked else { throw EditorError.transitionInProgress }
        guard status != .trashed else { throw RepositoryError.cardUnavailable }
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        guard let line = lines.first(where: { $0.id == lineID }) else { throw RepositoryError.lineUnavailable }
        let updated = try await repository.updateLine(LineMutation(id: lineID, kind: kind, text: line.text, reminder: line.reminder), now: .now)
        replace(updated)
    }

    func setCompleted(lineID: LineID, completed: Bool) async throws {
        guard !isTransitionLocked else { throw EditorError.transitionInProgress }
        guard status != .trashed else { throw RepositoryError.cardUnavailable }
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        try await repository.setCompleted(lineID: lineID, completed: completed, now: .now)
        lines = try await repository.lines(cardID: cardID)
    }

    func reorder(orderedLineIDs: [LineID]) async throws {
        guard !isTransitionLocked else { throw EditorError.transitionInProgress }
        guard status != .trashed else { throw RepositoryError.cardUnavailable }
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        try await repository.reorder(cardID: cardID, orderedLineIDs: orderedLineIDs, now: .now)
        lines = try await repository.lines(cardID: cardID)
    }

    func move(lineID: LineID, direction: MoveDirection) async throws {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { throw RepositoryError.lineUnavailable }
        let destination = index + (direction == .up ? -1 : 1)
        guard lines.indices.contains(destination) else { return }
        var ids = lines.map(\.id)
        ids.swapAt(index, destination)
        try await reorder(orderedLineIDs: ids)
    }

    func editTitle(_ value: String) {
        guard status != .trashed, !isTransitionLocked else { return }
        title = value
        unsavedTitle = value
        scheduleSave()
    }

    func editText(lineID: LineID, text: String) {
        guard status != .trashed, !isTransitionLocked else { return }
        unsavedText[lineID] = text
        scheduleSave()
    }

    func editNewLine(_ value: String) {
        guard status != .trashed, !isTransitionLocked else { return }
        newLineDraft = value
        newLineRevision += 1
    }

    @discardableResult
    func submitNewLine() async throws -> Bool {
        guard !isTransitionLocked else { throw EditorError.transitionInProgress }
        guard status != .trashed else { throw RepositoryError.cardUnavailable }
        guard !isAddingLine else { return false }
        let rawDraft = newLineDraft
        let submittedRevision = newLineRevision
        let text = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        isAddingLine = true
        defer {
            isAddingLine = false
            let waiters = submissionWaiters
            submissionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            guard await drainDrafts() else { throw EditorError.pendingSaveFailed }
            let line = try await repository.addLine(NewLineDraft(cardID: cardID, kind: .todo, text: text), now: .now)
            lines.append(line)
            if newLineRevision == submittedRevision { newLineDraft = "" }
            newLineError = nil
            return true
        } catch {
            newLineError = error.localizedDescription
            throw error
        }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = await self?.flushPending()
        }
    }

    func flushPending() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        if isAddingLine {
            await withCheckedContinuation { submissionWaiters.append($0) }
        }
        return await drainDrafts()
    }

    func retry() async -> Bool { await flushPending() }

    private func drainDrafts() async -> Bool {
        while true {
            if let activeSave {
                guard await activeSave.value else { return false }
                continue
            }
            guard unsavedTitle != nil || !unsavedText.isEmpty else {
                saveState = .saved
                return true
            }
            let task = Task { [self] in
                let result = await saveOnePass()
                activeSave = nil
                return result
            }
            activeSave = task
            guard await task.value else { return false }
        }
    }

    private func saveOnePass() async -> Bool {
        saveState = .saving
        do {
            if let pendingTitle = unsavedTitle {
                _ = try await repository.updateCardTitle(cardID, title: pendingTitle, now: .now)
                if unsavedTitle == pendingTitle { unsavedTitle = nil }
            }
            let pendingLines = unsavedText
            for (id, draft) in pendingLines {
                guard let line = lines.first(where: { $0.id == id }) else { throw RepositoryError.lineUnavailable }
                let updated = try await repository.updateLine(LineMutation(id: id, kind: line.kind, text: draft, reminder: line.reminder), now: .now)
                replace(updated)
                if unsavedText[id] == draft { unsavedText.removeValue(forKey: id) }
            }
            if unsavedTitle == nil && unsavedText.isEmpty { saveState = .saved }
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            return false
        }
    }

    private func replace(_ line: CardLine) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        lines[index] = line
    }
}
