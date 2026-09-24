import Foundation
import Observation
import PetalCore
import PetalPersistence

enum SaveState: Equatable {
    case saved
    case saving
    case failed(String)
}

enum EditorError: Error { case pendingSaveFailed }

@MainActor @Observable
final class CardEditorModel {
    let cardID: CardID
    private let repository: any PetalRepository
    private(set) var title = ""
    private(set) var lines: [CardLine] = []
    private(set) var unsavedText: [LineID: String] = [:]
    private(set) var unsavedTitle: String?
    private(set) var saveState: SaveState = .saved
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var saving = false

    init(cardID: CardID, repository: any PetalRepository) {
        self.cardID = cardID
        self.repository = repository
    }

    func load() async throws {
        guard let card = try await repository.card(id: cardID) else { throw RepositoryError.cardUnavailable }
        title = card.title
        lines = try await repository.lines(cardID: cardID)
    }

    func addLine(text: String) async throws {
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        let line = try await repository.addLine(NewLineDraft(cardID: cardID, kind: .todo, text: text), now: .now)
        lines.append(line)
    }

    func convert(lineID: LineID, to kind: LineKind) async throws {
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        guard let line = lines.first(where: { $0.id == lineID }) else { throw RepositoryError.lineUnavailable }
        let updated = try await repository.updateLine(LineMutation(id: lineID, kind: kind, text: line.text, reminder: line.reminder), now: .now)
        replace(updated)
    }

    func setCompleted(lineID: LineID, completed: Bool) async throws {
        guard await flushPending() else { throw EditorError.pendingSaveFailed }
        try await repository.setCompleted(lineID: lineID, completed: completed, now: .now)
        lines = try await repository.lines(cardID: cardID)
    }

    func reorder(orderedLineIDs: [LineID]) async throws {
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
        title = value
        unsavedTitle = value
        scheduleSave()
    }

    func editText(lineID: LineID, text: String) {
        unsavedText[lineID] = text
        scheduleSave()
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = await self?.persistDrafts()
        }
    }

    func flushPending() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        return await persistDrafts()
    }

    func retry() async -> Bool { await flushPending() }

    private func persistDrafts() async -> Bool {
        guard !saving else { return false }
        guard unsavedTitle != nil || !unsavedText.isEmpty else { saveState = .saved; return true }
        saving = true
        saveState = .saving
        defer { saving = false }
        do {
            if let pendingTitle = unsavedTitle {
                _ = try await repository.updateCardTitle(cardID, title: pendingTitle, now: .now)
                if unsavedTitle == pendingTitle { unsavedTitle = nil }
            }
            for (id, draft) in unsavedText {
                guard let line = lines.first(where: { $0.id == id }) else { throw RepositoryError.lineUnavailable }
                let updated = try await repository.updateLine(LineMutation(id: id, kind: line.kind, text: draft, reminder: line.reminder), now: .now)
                replace(updated)
                if unsavedText[id] == draft { unsavedText.removeValue(forKey: id) }
            }
            saveState = .saved
            if unsavedTitle != nil || !unsavedText.isEmpty { scheduleSave() }
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
