import Foundation
import SwiftData
import PetalCore

public struct SwiftDataPetalRepository: PetalRepository {
    private let store: RepositoryStore

    public init(container: PetalStore, faultInjector: RepositoryFaultInjector = .none) {
        store = RepositoryStore(container: container, faultInjector: faultInjector)
    }

    public func bootstrap(now: Date) async throws { try await store.bootstrap(now: now) }
    public func cards(scope: CardScope) async throws -> [Card] { try await store.cards(scope: scope) }
    public func card(id: CardID) async throws -> Card? { try await store.cards(scope: .all).first { $0.id == id } }
    public func createCard(title: String, now: Date) async throws -> Card {
        try await store.createCard(title: title, now: now)
    }
    public func updateCardTitle(_ id: CardID, title: String, now: Date) async throws -> Card {
        try await store.updateCardTitle(id, title: title, now: now)
    }
    public func pendingOutboxCount() async throws -> Int { try await store.pendingOutboxCount() }
    public func pendingOutbox() async throws -> [OutboxChange] { try await store.pendingOutbox() }
    public func lines(cardID: CardID) async throws -> [CardLine] { try await store.lines(cardID: cardID) }
    public func addLine(_ draft: NewLineDraft, now: Date) async throws -> CardLine { try await store.addLine(draft, now: now) }
    public func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine { try await store.updateLine(mutation, now: now) }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws {
        try await store.setCompleted(lineID: lineID, completed: completed, now: now)
    }
    public func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) async throws {
        try await store.reorder(cardID: cardID, orderedLineIDs: orderedLineIDs, now: now)
    }
    public func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws {
        try await store.moveCard(id, to: status, replacementInbox: replacementInbox, now: now)
    }
    public func moveCardEnsuringInbox(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws {
        try await store.moveCardEnsuringInbox(id, to: status, replacementInbox: replacementInbox, now: now)
    }
    public func search(_ query: String) async throws -> [SearchResult] { try await store.search(query) }
    public func purgeExpiredTrash(now: Date) async throws { try await store.purgeExpiredTrash(now: now) }
    public func captureConflict(cardID: CardID, lineID: LineID?, losingPayload: Data, now: Date) async throws -> ConflictArtifact {
        try await store.captureConflict(cardID: cardID, lineID: lineID, losingPayload: losingPayload, now: now)
    }
    public func conflicts() async throws -> [ConflictArtifact] { try await store.conflicts() }
    public func purgeExpiredConflicts(now: Date) async throws { try await store.purgeExpiredConflicts(now: now) }
    public func deleteAllData(resetGeneration: UUID, now: Date) async throws {
        try await store.deleteAllData(resetGeneration: resetGeneration, now: now)
    }
    public func resetGeneration() async throws -> UUID? { try await store.resetGeneration() }
}

@ModelActor
private actor RepositoryStore {
    private var faultInjector: RepositoryFaultInjector = .none
    private var coordinator = StoreCoordinator()
    private var transactionContext: ModelContext?
    // Fresh read contexts prevent stale registered objects after another process saves.
    private var context: ModelContext { transactionContext ?? ModelContext(modelContainer) }

    init(container: PetalStore, faultInjector: RepositoryFaultInjector) {
        modelContainer = container.container
        let context = ModelContext(container.container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.faultInjector = faultInjector
        coordinator = container.coordinator
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try coordinator.withLock {
            let session = ModelContext(modelContainer)
            session.autosaveEnabled = false
            transactionContext = session
            defer { transactionContext = nil }
            do {
                let result = try body()
                if faultInjector == .failBeforeSave { throw RepositoryError.injectedFailure }
                if faultInjector == .failOnceBeforeSave {
                    faultInjector = .none
                    throw RepositoryError.injectedFailure
                }
                try session.save()
                return result
            } catch {
                session.rollback()
                throw error
            }
        }
    }

    private func insertCard(title: String, isInbox: Bool, now: Date) throws -> Card {
        let card = Card(id: CardID(rawValue: UUID()), title: title, status: .active,
                        themeID: .cream, isInbox: isInbox, createdAt: now, modifiedAt: now,
                        archivedAt: nil, deletedAt: nil, revision: 1, deviceID: try deviceID())
        let stored = try PetalSchemaV1.StoredCard(card)
        context.insert(stored)
        try appendChange(entity: .card, id: stored.id, payload: stored.payload, now: now)
        return card
    }

    func bootstrap(now: Date) throws {
        try transaction {
            if try !cards(scope: .active).contains(where: \.isInbox) {
                _ = try insertCard(title: "Inbox", isInbox: true, now: now)
            }
        }
    }

    func createCard(title: String, now: Date) throws -> Card {
        try transaction {
            try insertCard(title: title, isInbox: !cards(scope: .active).contains(where: \.isInbox), now: now)
        }
    }

    func pendingOutboxCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>())
    }

    func pendingOutbox() throws -> [OutboxChange] {
        try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()).map { try $0.value() }
            .sorted { $0.sequence < $1.sequence }
    }

    private func appendChange(entity: OutboxChange.Entity, id: UUID, payload: Data, now: Date,
                              operation: OutboxChange.Operation = .upsert) throws {
        let state = try userState()
        state.nextOutboxSequence += 1
        context.insert(try PetalSchemaV1.StoredOutboxChange(OutboxChange(
            id: UUID(), entity: entity, entityID: id, operation: operation, payload: payload,
            createdAt: now, sequence: state.nextOutboxSequence
        )))
    }

    func lines(cardID: CardID) throws -> [CardLine] {
        let id = cardID.rawValue
        return try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>(predicate: #Predicate { $0.cardID == id }))
            .map { try $0.value() }.filter { $0.deletedAt == nil }
            .sorted { $0.sortIndex == $1.sortIndex
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.sortIndex < $1.sortIndex }
    }

    func addLine(_ draft: NewLineDraft, now: Date) throws -> CardLine {
        try transaction {
            guard try cards(scope: .all).contains(where: { $0.id == draft.cardID && $0.status != .trashed }) else {
                throw RepositoryError.cardUnavailable
            }
            let index = try (lines(cardID: draft.cardID).map(\.sortIndex).max() ?? -1) + 1
            let completed = draft.kind == .todo && draft.isCompleted
            let value = CardLine(id: LineID(rawValue: UUID()), cardID: draft.cardID, kind: draft.kind,
                                 text: draft.text, sortIndex: index, isCompleted: completed,
                                 completedAt: completed ? now : nil, lastDailyCompletionKey: nil,
                                 dailyStreak: 0, reminder: draft.kind == .todo ? draft.reminder : nil,
                                 createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: try deviceID())
            let stored = try PetalSchemaV1.StoredLine(value)
            context.insert(stored)
            try appendChange(entity: .line, id: stored.id, payload: stored.payload, now: now)
            return value
        }
    }

    private func storedLine(_ id: LineID) throws -> PetalSchemaV1.StoredLine {
        let rawID = id.rawValue
        guard let stored = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>(
            predicate: #Predicate { $0.id == rawID }
        )).first, try stored.value().deletedAt == nil else { throw RepositoryError.lineUnavailable }
        let cardID = try stored.value().cardID
        guard try cards(scope: .all).contains(where: { $0.id == cardID && $0.status != .trashed }) else {
            throw RepositoryError.cardUnavailable
        }
        return stored
    }

    private func saveLine(_ value: CardLine, stored: PetalSchemaV1.StoredLine, now: Date) throws {
        var updated = value
        updated.revision += 1
        updated.modifiedAt = now
        updated.deviceID = try deviceID()
        stored.payload = try JSONEncoder().encode(updated)
        try appendChange(entity: .line, id: stored.id, payload: stored.payload, now: now)
    }

    func updateLine(_ mutation: LineMutation, now: Date) throws -> CardLine {
        try transaction {
            let stored = try storedLine(mutation.id)
            var value = try stored.value()
            value.kind = mutation.kind
            value.text = mutation.text
            value.reminder = mutation.kind == .todo ? mutation.reminder : nil
            if mutation.kind == .text {
                value.isCompleted = false
                value.completedAt = nil
                value.lastDailyCompletionKey = nil
                value.dailyStreak = 0
            }
            try saveLine(value, stored: stored, now: now)
            return try stored.value()
        }
    }

    func setCompleted(lineID: LineID, completed: Bool, now: Date) throws {
        try transaction {
            let stored = try storedLine(lineID)
            var value = try stored.value()
            guard value.kind == .todo else { throw RepositoryError.lineUnavailable }
            guard value.isCompleted != completed else { return }
            value.isCompleted = completed
            value.completedAt = completed ? now : nil
            try saveLine(value, stored: stored, now: now)
        }
    }

    func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) throws {
        try transaction {
            guard try cards(scope: .all).contains(where: { $0.id == cardID && $0.status != .trashed }) else {
                throw RepositoryError.cardUnavailable
            }
            let existing = try lines(cardID: cardID)
            guard orderedLineIDs.count == existing.count,
                  Set(orderedLineIDs) == Set(existing.map(\.id)) else { throw RepositoryError.invalidOrder }
            for (index, id) in orderedLineIDs.enumerated() {
                let stored = try storedLine(id)
                var value = try stored.value()
                guard value.sortIndex != Int64(index) else { continue }
                value.sortIndex = Int64(index)
                try saveLine(value, stored: stored, now: now)
            }
        }
    }

    private func storedCard(_ id: CardID) throws -> PetalSchemaV1.StoredCard {
        let rawID = id.rawValue
        guard let card = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>(
            predicate: #Predicate { $0.id == rawID }
        )).first else { throw RepositoryError.cardUnavailable }
        return card
    }

    private func saveCard(_ value: Card, stored: PetalSchemaV1.StoredCard, now: Date) throws {
        var updated = value
        updated.revision += 1
        updated.modifiedAt = now
        updated.deviceID = try deviceID()
        stored.payload = try JSONEncoder().encode(updated)
        try appendChange(entity: .card, id: stored.id, payload: stored.payload, now: now)
    }

    func updateCardTitle(_ id: CardID, title: String, now: Date) throws -> Card {
        try transaction {
            let stored = try storedCard(id)
            var value = try stored.value()
            guard value.status != .trashed else { throw RepositoryError.cardUnavailable }
            guard value.title != title else { return value }
            value.title = title
            try saveCard(value, stored: stored, now: now)
            return try stored.value()
        }
    }

    func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) throws {
        try transaction { try applyMoveCard(id, to: status, replacementInbox: replacementInbox, createReplacement: false, now: now) }
    }

    func moveCardEnsuringInbox(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) throws {
        try transaction { try applyMoveCard(id, to: status, replacementInbox: replacementInbox, createReplacement: true, now: now) }
    }

    private func applyMoveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?,
                               createReplacement: Bool, now: Date) throws {
            let stored = try storedCard(id)
            var value = try stored.value()
            guard value.status != status else { return }
            if value.isInbox && status != .active {
                let candidates = try cards(scope: .active).filter { $0.id != id }
                let selected = replacementInbox ?? (createReplacement && candidates.count == 1 ? candidates[0].id : nil)
                if let selected, let replacementValue = candidates.first(where: { $0.id == selected }) {
                    var replacement = replacementValue
                    replacement.isInbox = true
                    try saveCard(replacement, stored: storedCard(selected), now: now)
                } else if selected == nil && createReplacement && candidates.isEmpty {
                    _ = try insertCard(title: "Inbox", isInbox: true, now: now)
                } else {
                    throw RepositoryError.replacementInboxRequired
                }
                value.isInbox = false
            }
            value.status = status
            value.archivedAt = status == .archived ? now : nil
            value.deletedAt = status == .trashed ? now : nil
            try saveCard(value, stored: stored, now: now)
    }

    func search(_ query: String) throws -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var results: [SearchResult] = []
        for card in try cards(scope: .all) {
            if card.title.localizedCaseInsensitiveContains(needle) {
                results.append(SearchResult(cardID: card.id, lineID: nil, title: card.title, snippet: card.title))
            }
            for line in try lines(cardID: card.id) where line.text.localizedCaseInsensitiveContains(needle) {
                results.append(SearchResult(cardID: card.id, lineID: line.id, title: card.title, snippet: line.text))
            }
        }
        return results
    }

    func purgeExpiredTrash(now: Date) throws {
        try transaction {
            for card in try cards(scope: .trashed) {
                guard let deletedAt = card.deletedAt, now.timeIntervalSince(deletedAt) >= 2_592_000 else { continue }
                let cardID = card.id.rawValue
                for line in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>(predicate: #Predicate { $0.cardID == cardID })) {
                    try appendDeletion(entity: .line, id: line.id, now: now)
                    context.delete(line)
                }
                let stored = try storedCard(card.id)
                try appendDeletion(entity: .card, id: stored.id, now: now)
                context.delete(stored)
            }
        }
    }

    func captureConflict(cardID: CardID, lineID: LineID?, losingPayload: Data, now: Date) throws -> ConflictArtifact {
        try transaction {
            let value = ConflictArtifact(id: UUID(), cardID: cardID, lineID: lineID,
                                         losingPayload: losingPayload, capturedAt: now,
                                         expiresAt: now.addingTimeInterval(2_592_000), hasBeenPresented: false)
            let stored = try PetalSchemaV1.StoredConflictArtifact(value)
            context.insert(stored)
            try appendChange(entity: .conflict, id: stored.id, payload: stored.payload, now: now)
            return value
        }
    }

    func conflicts() throws -> [ConflictArtifact] {
        try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()).map { try $0.value() }
            .sorted { $0.capturedAt == $1.capturedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt }
    }

    func purgeExpiredConflicts(now: Date) throws {
        try transaction {
            for stored in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>(
                predicate: #Predicate { $0.expiresAt <= now }
            )) {
                try appendDeletion(entity: .conflict, id: stored.id, now: now)
                context.delete(stored)
            }
        }
    }

    func resetGeneration() throws -> UUID? {
        try context.fetch(FetchDescriptor<PetalSchemaV1.StoredUserState>()).first?.resetGeneration
    }

    private func appendDeletion(entity: OutboxChange.Entity, id: UUID, now: Date) throws {
        // Retention also applies to queued snapshots: never keep expired user content
        // in an earlier upsert or in a physical deletion's payload.
        for stored in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) {
            let change = try stored.value()
            if change.entity == entity && change.entityID == id { context.delete(stored) }
        }
        try appendChange(entity: entity, id: id, payload: Data(), now: now, operation: .delete)
    }

    private func deviceID() throws -> String {
        try userState().deviceID
    }

    private func userState() throws -> PetalSchemaV1.StoredUserState {
        if let state = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredUserState>()).first { return state }
        // Device identity and journal sequence are local metadata, not standalone changes.
        let state = PetalSchemaV1.StoredUserState(resetGeneration: nil)
        context.insert(state)
        return state
    }

    func deleteAllData(resetGeneration: UUID, now: Date) throws {
        try transaction {
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredImportFingerprint>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) { context.delete(value) }
            let state: PetalSchemaV1.StoredUserState
            if let existing = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredUserState>()).first {
                state = existing
                state.resetGeneration = resetGeneration
            } else {
                state = PetalSchemaV1.StoredUserState(resetGeneration: resetGeneration)
                context.insert(state)
            }
            let inbox = try insertCard(title: "Inbox", isInbox: true, now: now)
            let payload = try JSONEncoder().encode(UserStateChange(resetGeneration: resetGeneration, inboxCardID: inbox.id))
            try appendChange(entity: .userState, id: resetGeneration, payload: payload, now: now)
        }
    }

    func cards(scope: CardScope) throws -> [Card] {
        try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>())
            .map { try $0.value() }
            .filter { scope == .all || $0.status.rawValue == scope.rawValue }
            .sorted { $0.createdAt == $1.createdAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.createdAt < $1.createdAt }
    }
}
