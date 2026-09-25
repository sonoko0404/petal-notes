import Foundation
import SwiftData
import PetalCore

public struct SwiftDataPetalRepository: PetalSyncRepository, PetalTransferRepository {
    private let store: RepositoryStore

    public init(container: PetalStore, faultInjector: RepositoryFaultInjector = .none) {
        store = RepositoryStore(container: container, faultInjector: faultInjector)
    }

    public func bootstrap(now: Date) async throws { try await store.bootstrap(now: now) }
    public func bootstrapOnboarding(seed: OnboardingSeed, now: Date) async throws -> Bool {
        try await store.bootstrapOnboarding(seed: seed, now: now)
    }
    public func completeOnboarding() async throws { try await store.completeOnboarding() }
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
    public func captureTodoLines(cardID: CardID, texts: [String], now: Date) async throws -> [CardLine] {
        try await store.captureTodoLines(cardID: cardID, texts: texts, now: now)
    }
    public func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine { try await store.updateLine(mutation, now: now) }
    public func deleteLine(lineID: LineID, now: Date) async throws { try await store.deleteLine(lineID: lineID, now: now) }
    public func setReminder(lineID: LineID, reminder: Reminder?, now: Date) async throws -> CardLine {
        try await store.setReminder(lineID: lineID, reminder: reminder, now: now)
    }
    public func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws {
        try await store.setCompleted(lineID: lineID, completed: completed, now: now)
    }

    public func setWidgetCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) async throws {
        try await store.setWidgetCompleted(lineID: lineID, completed: completed, now: now, calendar: calendar)
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
    public func recoverConflict(id: UUID, now: Date) async throws -> CardID { try await store.recoverConflict(id: id, now: now) }
    public func purgeExpiredConflicts(now: Date) async throws { try await store.purgeExpiredConflicts(now: now) }
    public func deleteAllData(resetGeneration: UUID, now: Date) async throws {
        try await store.deleteAllData(resetGeneration: resetGeneration, now: now)
    }
    public func resetGeneration() async throws -> UUID? { try await store.resetGeneration() }
    public func syncSnapshot() async throws -> SyncSnapshot { try await store.syncSnapshot() }
    public func widgetSyncStatus() async throws -> WidgetSyncStatus { try await store.widgetSyncStatus() }
    public func acknowledgeSync(_ sent: [OutboxChange], token: Data? = nil, expectedEpoch: UInt64? = nil) async throws {
        try await store.acknowledgeSync(sent, token: token, expectedEpoch: expectedEpoch)
    }
    public func setSyncEnabled(_ enabled: Bool) async throws { try await store.setSyncEnabled(enabled) }
    public func applyInbound(_ records: [ReplicatedRecord], token: Data?, now: Date, expectedEpoch: UInt64? = nil) async throws {
        try await store.applyInbound(records, token: token, now: now, expectedEpoch: expectedEpoch)
    }
    public func takeUnpresentedConflicts(now: Date) async throws -> [ConflictArtifact] {
        try await store.takeUnpresentedConflicts(now: now)
    }
    public func recordSyncState(_ state: SyncState, retryAt: Date?, expectedEpoch: UInt64? = nil) async throws {
        try await store.recordSyncState(state, retryAt: retryAt, expectedEpoch: expectedEpoch)
    }
    public func finishResetCleanup() async throws { try await store.finishResetCleanup() }
    public func finishErasureScan(generation: UUID, token: Data?, expectedEpoch: UInt64?) async throws {
        try await store.finishErasureScan(generation: generation, token: token, expectedEpoch: expectedEpoch)
    }
    public func transferSnapshot() async throws -> TransferSnapshot { try await store.transferSnapshot() }
    public func importCards(_ cards: [ImportedCard], now: Date,
        backup: @Sendable (TransferSnapshot) throws -> Void) async throws -> Int {
        try await store.importCards(cards, now: now, backup: backup)
    }
    public func replaceUserData(_ snapshot: TransferSnapshot, now: Date) async throws {
        try await store.replaceUserData(snapshot, now: now)
    }
}

@ModelActor
private actor RepositoryStore {
    private var faultInjector: RepositoryFaultInjector = .none
    private var coordinator = StoreCoordinator()
    private var transactionContext: ModelContext?
    private var resetFenceInstalled = false
    // Fresh read contexts prevent stale registered objects after another process saves.
    private var context: ModelContext { transactionContext ?? ModelContext(modelContainer) }

    private func rawTransferSnapshot() throws -> TransferSnapshot {
        TransferSnapshot(cards: try cards(scope: .all),
            lines: try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).map { try $0.value() })
    }

    func transferSnapshot() throws -> TransferSnapshot {
        try coordinator.withLock { try rawTransferSnapshot() }
    }

    func replaceUserData(_ snapshot: TransferSnapshot, now: Date) throws {
        try snapshot.validate()
        try transaction {
            let previous = try syncMetadata().generation
            let generation = ResetGeneration(id: UUID(), modifiedAt: max(now, previous.modifiedAt.addingTimeInterval(0.001)),
                deviceID: try deviceID(), isReplacement: true)
            try resetContents(generation: generation, now: now, replacement: snapshot)
        }
    }

    func importCards(_ entries: [ImportedCard], now: Date,
                     backup: @Sendable (TransferSnapshot) throws -> Void) throws -> Int {
        try TransferSnapshot(cards: entries.map(\.card), lines: entries.flatMap(\.lines)).validate()
        guard entries.allSatisfy({ entry in !entry.card.isInbox && !entry.fingerprint.isEmpty
            && entry.lines.allSatisfy { $0.cardID == entry.card.id } }) else { throw TransferRepositoryError.invalidSnapshot }
        return try transaction {
            let before = try rawTransferSnapshot()
            // Snapshot and durable backup happen under the same cross-process lock as the save.
            // No rows, fingerprints, user-state sequence, or outbox entries have changed yet.
            try backup(before)
            var fingerprints = Set(try context.fetch(FetchDescriptor<PetalSchemaV1.StoredImportFingerprint>()).map(\.fingerprint))
            var count = 0
            var identities = Set(before.cards.map { $0.id.rawValue } + before.lines.map { $0.id.rawValue })
            for entry in entries where !fingerprints.contains(entry.fingerprint) {
                let sourceKey = "windows-note:" + entry.sourceNoteID.uuidString.lowercased()
                guard !fingerprints.contains(sourceKey) else { continue }
                guard identities.insert(entry.card.id.rawValue).inserted,
                      entry.lines.allSatisfy({ identities.insert($0.id.rawValue).inserted && $0.cardID == entry.card.id }) else {
                    throw TransferRepositoryError.invalidSnapshot
                }
                var card = entry.card
                card.deviceID = try deviceID()
                let stored = try PetalSchemaV1.StoredCard(card)
                context.insert(stored)
                try appendChange(entity: .card, id: stored.id, payload: stored.payload, now: now)
                for var line in entry.lines {
                    line.deviceID = card.deviceID
                    let storedLine = try PetalSchemaV1.StoredLine(line)
                    context.insert(storedLine)
                    try appendChange(entity: .line, id: storedLine.id, payload: storedLine.payload, now: now)
                }
                context.insert(PetalSchemaV1.StoredImportFingerprint(fingerprint: entry.fingerprint, importedAt: now))
                context.insert(PetalSchemaV1.StoredImportFingerprint(fingerprint: sourceKey, importedAt: now))
                fingerprints.insert(entry.fingerprint)
                fingerprints.insert(sourceKey)
                count += 1
            }
            if count > 0 { try repairInbox(now: now) }
            return count
        }
    }

    init(container: PetalStore, faultInjector: RepositoryFaultInjector) {
        modelContainer = container.container
        let context = ModelContext(container.container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.faultInjector = faultInjector
        coordinator = container.coordinator
    }

    private func transaction<T>(notify: Bool = true, _ body: () throws -> T) throws -> T {
        try coordinator.withLock {
            let session = ModelContext(modelContainer)
            session.autosaveEnabled = false
            transactionContext = session
            resetFenceInstalled = false
            defer { transactionContext = nil; resetFenceInstalled = false }
            do {
                let result = try body()
                if faultInjector == .failBeforeSave { throw RepositoryError.injectedFailure }
                if faultInjector == .failOnceBeforeSave {
                    faultInjector = .none
                    throw RepositoryError.injectedFailure
                }
                let changed = session.hasChanges
                try session.save()
                if notify && changed { coordinator.publishCommit() }
                return result
            } catch {
                session.rollback()
                if resetFenceInstalled, let generation = try? syncMetadata().generation.id {
                    // A failed reset must not leave an expected future generation
                    // permanently blocking fresh reads of the retained data.
                    try? coordinator.installWidgetResetFence(generation: generation)
                }
                throw error
            }
        }
    }

    private func insertCard(title: String, isInbox: Bool, now: Date, id: UUID = UUID()) throws -> Card {
        let card = Card(id: CardID(rawValue: id), title: title, status: .active,
                        themeID: .cream, isInbox: isInbox, createdAt: now, modifiedAt: now,
                        archivedAt: nil, deletedAt: nil, revision: 1, deviceID: try deviceID())
        let stored = try PetalSchemaV1.StoredCard(card)
        context.insert(stored)
        try appendChange(entity: .card, id: stored.id, payload: stored.payload, now: now)
        return card
    }

    func bootstrapOnboarding(seed: OnboardingSeed, now: Date) throws -> Bool {
        try transaction {
            var metadata = try syncMetadata()
            if let completed = metadata.onboardingCompleted { return !completed }
            let fresh = try cards(scope: .all).isEmpty && metadata.generation == .initial
            if fresh {
                guard seed.todos.count == 3 else { throw TransferRepositoryError.invalidSnapshot }
                _ = try insertCard(title: seed.inbox, isInbox: true, now: now)
                let sample = try insertCard(title: seed.title, isInbox: false, now: now)
                for (index, text) in seed.todos.enumerated() {
                    _ = try insertLine(NewLineDraft(cardID: sample.id, kind: .todo, text: text), sortIndex: Int64(index), now: now)
                }
            }
            metadata.onboardingCompleted = !fresh
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            return fresh
        }
    }

    func completeOnboarding() throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            metadata.onboardingCompleted = true
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    func bootstrap(now: Date) throws {
        try transaction {
            if try !cards(scope: .active).contains(where: \.isInbox) {
                _ = try insertCard(title: PetalStrings.text("ui.inbox.94835e"), isInbox: true, now: now)
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

    private func syncMetadata() throws -> LocalSyncMetadata {
        guard let data = try context.fetch(FetchDescriptor<PetalSchemaV2.StoredSyncMetadata>()).first?.payload else {
            return LocalSyncMetadata()
        }
        return try JSONDecoder().decode(LocalSyncMetadata.self, from: data)
    }

    private func syncMetadataRow() throws -> PetalSchemaV2.StoredSyncMetadata {
        if let row = try context.fetch(FetchDescriptor<PetalSchemaV2.StoredSyncMetadata>()).first { return row }
        let row = PetalSchemaV2.StoredSyncMetadata(); context.insert(row); return row
    }

    func finishResetCleanup() throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            guard metadata.resetCleanupPending else { return }
            // The durable flag was set with the reset transaction. Removing the
            // recovery file is idempotent if a crash occurs before clearing it.
            try coordinator.removeMigrationRecoverySnapshot()
            try coordinator.eraseWidgetSnapshots()
            metadata.resetCleanupPending = false
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    func syncSnapshot() throws -> SyncSnapshot {
        try coordinator.withLock {
            let metadata = try syncMetadata()
            return SyncSnapshot(enabled: metadata.enabled, changes: try pendingOutbox(), token: metadata.token,
                         tombstones: metadata.tombstones, generation: metadata.generation,
                         state: metadata.state, retryAt: metadata.retryAt,
                         preferenceEpoch: metadata.preferenceEpoch ?? 0,
                         replacementExpectedInboxID: metadata.replacementExpectedInboxID,
                         replacementDeliveryStatus: metadata.replacementDeliveryStatus,
                         erasureScanGeneration: metadata.erasureScanGeneration)
        }
    }

    func widgetSyncStatus() throws -> WidgetSyncStatus {
        try coordinator.withLock {
            let metadata = try syncMetadata()
            return WidgetSyncStatus(enabled: metadata.enabled, state: metadata.state, generation: metadata.generation)
        }
    }

    private func validateSyncEpoch(_ expected: UInt64?, _ metadata: LocalSyncMetadata) throws {
        if let expected, !metadata.enabled || expected != (metadata.preferenceEpoch ?? 0) {
            throw RepositoryError.syncSessionSuperseded
        }
    }

    func finishErasureScan(generation: UUID, token: Data?, expectedEpoch: UInt64?) throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            try validateSyncEpoch(expectedEpoch, metadata)
            guard metadata.erasureScanGeneration == generation else { return }
            // All discovered redactions already share the committed inbound
            // transaction. A send failure or crash retains their journal work.
            metadata.erasureScanGeneration = nil
            metadata.token = token
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    func acknowledgeSync(_ sent: [OutboxChange], token: Data?, expectedEpoch: UInt64? = nil) throws {
        try transaction(notify: false) {
            try validateSyncEpoch(expectedEpoch, syncMetadata())
            let byID = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, $0) })
            for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) {
                if let expected = byID[row.id], try row.value() == expected { context.delete(row) }
            }
            if let token {
                var metadata = try syncMetadata(); metadata.token = token
                try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            }
            let metadata = try syncMetadata()
            if metadata.generation.isReplacement, metadata.replacementPlaceholderID == nil,
               metadata.authoritativeUserState?.replacementMode == true,
               try metadata.authoritativeUserState?.deviceID == deviceID(),
               try pendingOutbox().allSatisfy({ $0.entity == .conflict }),
               let inbox = try cards(scope: .active).first(where: \.isInbox) {
                // Durable follow-up intent, in the acknowledgement transaction.
                // A crash or failed clear send cannot leave it forgotten.
                try publishCurrentInbox(inbox.id, replacementMode: false,
                    now: metadata.authoritativeUserState?.modifiedAt ?? metadata.generation.modifiedAt)
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            metadata.enabled = enabled
            if !enabled { metadata.state = .offline }
            metadata.preferenceEpoch = (metadata.preferenceEpoch ?? 0) &+ 1
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    func applyInbound(_ records: [ReplicatedRecord], token: Data?, now: Date, expectedEpoch: UInt64? = nil) throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            try validateSyncEpoch(expectedEpoch, metadata)
            var invalid: [(ReplicatedRecord.Payload, StructuralIssue)] = []
            let candidates = (metadata.unresolvedLines ?? []) + records
            let cardIDs = Set(try cards(scope: .all).map { $0.id.rawValue }).union(candidates.compactMap {
                if case .card(let card) = $0.payload { return card.id.rawValue }
                if case .tombstone(let value) = $0.payload, value.entity == .card { return value.entityID }
                return nil
            })
            let lineIDs = Set(try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).map(\.id)).union(candidates.compactMap {
                if case .line(let line) = $0.payload { return line.id.rawValue }
                if case .tombstone(let value) = $0.payload, value.entity == .line { return value.entityID }
                return nil
            })
            let received = ((metadata.unresolvedLines ?? []) + records).filter { record in
                do {
                    try DomainStructure.validateDates([record.generation.modifiedAt])
                    if record.generation != .initial && DomainStructure.reservedRecordIDs.contains(record.generation.id) {
                        throw StructuralIssue.identity
                    }
                    switch record.payload {
                    case .card(let card):
                        try DomainStructure.validate(card)
                        if lineIDs.contains(card.id.rawValue) { throw StructuralIssue.identity }
                    case .line(let line):
                        try DomainStructure.validate(line)
                        if cardIDs.contains(line.id.rawValue) { throw StructuralIssue.identity }
                    case .invalidInbound: throw StructuralIssue.undecodableRecord
                    case .tombstone(let value):
                        guard !DomainStructure.reservedRecordIDs.contains(value.entityID) else { throw StructuralIssue.identity }
                        guard value.generation == nil || value.generation == record.generation else { throw StructuralIssue.identity }
                        if value.entity == .card ? lineIDs.contains(value.entityID) : cardIDs.contains(value.entityID) {
                            throw StructuralIssue.identity
                        }
                        try DomainStructure.validateDates([value.deletedAt])
                    case .userState(let value):
                        guard !DomainStructure.reservedRecordIDs.contains(value.inboxCardID.rawValue),
                              value.resetGeneration == record.generation.id else { throw StructuralIssue.identity }
                        guard (value.revision ?? 0) >= 0, (value.revision ?? 0) < Int64.max else { throw StructuralIssue.ordering }
                        try DomainStructure.validateDates([value.modifiedAt])
                    }
                } catch {
                    invalid.append((record.payload, (error as? StructuralIssue) ?? .undecodableRecord))
                    return false
                }
                return true
            }
            if let latest = received.map(\.generation).max(), latest > metadata.generation {
                try resetContents(generation: latest, now: now)
                metadata = try syncMetadata()
            }
            for (payload, reason) in invalid {
                switch payload {
                case .card(let card): try quarantine(card, cardID: card.id, lineID: nil, reason: reason, now: now)
                case .line(let line): try quarantine(line, cardID: line.cardID, lineID: line.id, reason: reason, now: now)
                case .invalidInbound(let metadata):
                    try quarantine(metadata, cardID: CardID(rawValue: metadata.entityID), lineID: nil, reason: reason, now: now)
                case .tombstone(let value):
                    try quarantine(value, cardID: CardID(rawValue: value.entityID),
                        lineID: value.entity == .line ? LineID(rawValue: value.entityID) : nil, reason: reason, now: now)
                case .userState(let value):
                    try quarantine(value, cardID: value.inboxCardID, lineID: nil, reason: reason, now: now)
                }
            }
            // A reset also cleans up stale records first discovered after the
            // local reset. The cleanup survives another offline failure.
            let erasureFence = metadata.erasureFence ?? (metadata.generation.isReplacement ? .initial : metadata.generation)
            let replacingIDs = Set(received.filter { $0.generation == metadata.generation }.compactMap { record -> UUID? in
                switch record.payload {
                case .card(let card): card.id.rawValue
                case .line(let line): line.id.rawValue
                default: nil
                }
            })
            for record in received where record.generation < erasureFence {
                let entity: SyncTombstone.Entity
                let id: UUID
                switch record.payload {
                case .card(let card): entity = .card; id = card.id.rawValue
                case .line(let line): entity = .line; id = line.id.rawValue
                default: continue
                }
                // A later restored copy at the same UUID is authoritative.
                if metadata.generation > erasureFence,
                   (try replacingIDs.contains(id) || cards(scope: .all).contains { $0.id.rawValue == id }
                    || context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).contains { $0.id == id }) { continue }
                if !metadata.tombstones.contains(where: { $0.entity == entity && $0.entityID == id }) {
                    metadata.tombstones.append(SyncTombstone(id: UUID(), entity: entity, entityID: id,
                        deletedAt: erasureFence.modifiedAt, deviceID: erasureFence.deviceID, revision: 1,
                        generation: erasureFence))
                }
                if try !pendingOutbox().contains(where: { $0.entityID == id && $0.operation == .delete }) {
                    try appendChange(entity: entity == .card ? .card : .line, id: id, payload: Data(), now: now, operation: .delete)
                }
            }
            let records = received.filter { $0.generation == metadata.generation }.sorted {
                func rank(_ value: ReplicatedRecord) -> Int {
                    switch value.payload { case .userState: 0; case .tombstone: 1; case .card: 2; case .line: 3; case .invalidInbound: 4 }
                }
                return rank($0) < rank($1)
            }
            // A replacement may arrive after its declaration and after an old
            // cleanup was queued/acknowledged. Its generation, not delivery
            // order or the 30-day retention window, owns the restored identity.
            let superseded = metadata.tombstones.filter {
                $0.generation.map { $0 < metadata.generation } == true && replacingIDs.contains($0.entityID)
            }
            for fence in superseded {
                try discardSupersededDeletion(entity: fence.entity == .card ? .card : .line, id: fence.entityID)
            }
            let supersededIDs = Set(superseded.map(\.id))
            metadata.tombstones.removeAll { supersededIDs.contains($0.id) }
            if metadata.generation.isReplacement {
                for record in records {
                    if case .userState(let state) = record.payload {
                        guard state.resetGeneration == metadata.generation.id else { continue }
                        let resolved = state.resolved(in: metadata.generation)
                        if metadata.authoritativeUserState.map({ resolved.isNewer(than: $0, in: metadata.generation) }) ?? true {
                            metadata.authoritativeUserState = resolved
                            // A remote winner invalidates an older pending marker,
                            // not unrelated card/line journal entries.
                            for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) {
                                let change = try row.value()
                                if change.entity == .userState { context.delete(row) }
                            }
                        }
                    }
                }
                if let state = metadata.authoritativeUserState {
                    metadata.replacementExpectedInboxID = state.inboxCardID.rawValue
                    if state.replacementMode == false { metadata.replacementInitialDeliveryComplete = true }
                } else if metadata.replacementExpectedInboxID == nil {
                    let declarations = Set(records.compactMap(\.replacementInboxID))
                    if declarations.count == 1 { metadata.replacementExpectedInboxID = declarations.first }
                }
            }
            var unresolved: [UUID: ReplicatedRecord] = [:]
            // Deletions are applied first, independent of server page ordering.
            for record in records {
                guard case .tombstone(let incoming) = record.payload else { continue }
                if let old = metadata.tombstones.first(where: { $0.entity == incoming.entity && $0.entityID == incoming.entityID }),
                   old.deletedAt > incoming.deletedAt || (old.deletedAt == incoming.deletedAt && old.deviceID >= incoming.deviceID) { continue }
                metadata.tombstones.removeAll { $0.entity == incoming.entity && $0.entityID == incoming.entityID }
                metadata.tombstones.append(incoming)
                var shouldRemove = true
                if incoming.entity == .card, let current = try cards(scope: .all).first(where: { $0.id.rawValue == incoming.entityID }) {
                    shouldRemove = incoming.prevents(modifiedAt: current.modifiedAt, deviceID: current.deviceID, now: now)
                } else if incoming.entity == .line,
                    let row = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).first(where: { $0.id == incoming.entityID }) {
                    let current = try row.value()
                    shouldRemove = incoming.prevents(modifiedAt: current.modifiedAt, deviceID: current.deviceID, now: now)
                }
                if shouldRemove { try removeEntity(incoming.entity, id: incoming.entityID) }
            }
            for record in records {
                switch record.payload {
                case .card(let card):
                    if metadata.tombstones.contains(where: { $0.entity == .card && $0.entityID == card.id.rawValue && $0.prevents(modifiedAt: card.modifiedAt, deviceID: card.deviceID, now: now) }) { continue }
                    if let row = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>()).first(where: { $0.id == card.id.rawValue }) {
                        let local = try row.value()
                        guard try mergeDecision(entity: .card, id: row.id, cardID: card.id, lineID: nil,
                            local: local, remote: card, localDate: local.modifiedAt, remoteDate: card.modifiedAt,
                            localDevice: local.deviceID, remoteDevice: card.deviceID,
                            userVisibleDifference: SyncConflictResolver.userVisibleDifference(local, card), now: now) else { continue }
                        row.payload = try JSONEncoder().encode(card)
                    } else {
                        context.insert(try PetalSchemaV1.StoredCard(card))
                        try discardSupersededDeletion(entity: .card, id: card.id.rawValue)
                    }
                    if metadata.generation.isReplacement && metadata.replacementInitialDeliveryComplete != true {
                        var candidates = metadata.replacementInitialInboxIDs ?? []
                        if card.isInbox && card.status == .active && card.archivedAt == nil && card.deletedAt == nil {
                            candidates.insert(card.id.rawValue)
                        } else { candidates.remove(card.id.rawValue) }
                        metadata.replacementInitialInboxIDs = candidates
                    }
                case .line(let line):
                    let existing = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).first { $0.id == line.id.rawValue }
                    do { try DomainStructure.validate(line, existingCardID: existing?.value().cardID) }
                    catch {
                        try quarantine(line, cardID: line.cardID, lineID: line.id, reason: .lineParent, now: now)
                        continue
                    }
                    if metadata.tombstones.contains(where: {
                        ($0.entity == .line && $0.entityID == line.id.rawValue || $0.entity == .card && $0.entityID == line.cardID.rawValue)
                            && !($0.generation.map { $0 < metadata.generation } ?? false)
                            && $0.prevents(modifiedAt: line.modifiedAt, deviceID: line.deviceID, now: now)
                    }) { continue }
                    guard try cards(scope: .all).contains(where: { $0.id == line.cardID }) else {
                        if let prior = unresolved[line.id.rawValue], case .line(let old) = prior.payload,
                           !SyncConflictResolver.remoteWins(localDate: old.modifiedAt, localDevice: old.deviceID,
                                remoteDate: line.modifiedAt, remoteDevice: line.deviceID) { continue }
                        unresolved[line.id.rawValue] = record
                        continue
                    }
                    if let row = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).first(where: { $0.id == line.id.rawValue }) {
                        let local = try row.value()
                        guard try mergeDecision(entity: .line, id: row.id, cardID: line.cardID, lineID: line.id,
                            local: local, remote: line, localDate: local.modifiedAt, remoteDate: line.modifiedAt,
                            localDevice: local.deviceID, remoteDevice: line.deviceID,
                            userVisibleDifference: SyncConflictResolver.userVisibleDifference(local, line), now: now) else { continue }
                        row.payload = try JSONEncoder().encode(line)
                    } else {
                        context.insert(try PetalSchemaV1.StoredLine(line))
                        try discardSupersededDeletion(entity: .line, id: line.id.rawValue)
                    }
                case .tombstone, .userState, .invalidInbound: break
                }
            }
            metadata.unresolvedLines = unresolved.values.sorted {
                guard case .line(let a) = $0.payload, case .line(let b) = $1.payload else { return false }
                return a.id.rawValue.uuidString < b.id.rawValue.uuidString
            }
            // Never evict recoverable children to make room: reject the whole
            // batch/checkpoint so the server can replay it after intervention.
            guard unresolved.count <= 4_096,
                  try JSONEncoder().encode(metadata.unresolvedLines).count <= 4_194_304 else {
                throw RepositoryError.unresolvedInboundCapacityExceeded
            }
            // Keep the applied checkpoint atomic with its page; the independent
            // durable erasureScanGeneration overrides this token until full scan.
            metadata.token = token
            let preferredInbox = try reconcileReplacement(&metadata, now: now)
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            try repairInbox(now: now, preferred: preferredInbox, replicateChanges: !metadata.generation.isReplacement)
        }
        // A Widget process can apply a cloud page too. Its foreground App has
        // no reference to that process's lifecycle coordinator; wake it by the
        // same content-free signal, without recursively requesting local sync.
        if !records.isEmpty { coordinator.publishCrossProcessCommit() }
    }

    private func reconcileReplacement(_ metadata: inout LocalSyncMetadata, now: Date) throws -> CardID? {
        guard metadata.generation.isReplacement else { return nil }
        let all = try cards(scope: .all)
        let expected = all.first { $0.id.rawValue == metadata.replacementExpectedInboxID }
        let initial = metadata.replacementInitialDeliveryComplete != true
        let valid = expected.map { $0.status == .active && $0.deletedAt == nil && $0.archivedAt == nil
            && (!initial || $0.isInbox || metadata.replacementInitialInboxIDs?.contains($0.id.rawValue) == true) } ?? false
        guard valid, let target = expected else {
            let quarantinedExpected = try conflicts().contains {
                $0.cardID.rawValue == metadata.replacementExpectedInboxID && $0.inboundIssue != nil && $0.expiresAt > now
            }
            if metadata.replacementExpectedInboxID == nil { metadata.replacementDeliveryStatus = .awaitingDeclaration }
            else if initial && (expected != nil || metadata.tombstones.contains { $0.entity == .card && $0.entityID == metadata.replacementExpectedInboxID }
                || quarantinedExpected) {
                metadata.replacementDeliveryStatus = .awaitingValidInitialInbox
            } else { metadata.replacementDeliveryStatus = .awaitingInbox }
            if !all.contains(where: { $0.status == .active && $0.archivedAt == nil && $0.deletedAt == nil }) {
                // A later lifecycle page can arrive after initial delivery but
                // before its new Inbox. This placeholder is local and disposable,
                // never a fabricated synchronized user card.
                let id = UUID()
                let card = Card(id: CardID(rawValue: id), title: PetalStrings.text("ui.inbox.94835e"), status: .active, themeID: .cream,
                    isInbox: true, createdAt: now, modifiedAt: now, archivedAt: nil, deletedAt: nil,
                    revision: 1, deviceID: try deviceID())
                context.insert(try PetalSchemaV1.StoredCard(card))
                metadata.replacementPlaceholderID = id
            }
            return metadata.replacementPlaceholderID.map(CardID.init(rawValue:))
        }
        if let placeholder = metadata.replacementPlaceholderID, placeholder != target.id.rawValue {
            let placeholderCard = all.first { $0.id.rawValue == placeholder }
            let hasChildren = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).contains { try $0.value().cardID.rawValue == placeholder }
            let hasPendingEdits = try pendingOutbox().contains { $0.entityID == placeholder }
            if placeholderCard?.revision == 1 && !hasChildren && !hasPendingEdits {
                try removeEntity(.card, id: placeholder)
            } else if var card = placeholderCard {
                card.isInbox = false
                try saveCard(card, stored: storedCard(card.id), now: max(now, card.modifiedAt.addingTimeInterval(0.001)))
            }
        }
        metadata.replacementPlaceholderID = nil
        metadata.replacementInitialDeliveryComplete = true
        metadata.replacementDeliveryStatus = .complete
        return target.id
    }

    private func publishCurrentInbox(_ inbox: CardID, replacementMode: Bool, now: Date) throws {
        var metadata = try syncMetadata()
        let previous = metadata.authoritativeUserState?.resolved(in: metadata.generation)
        guard (previous?.revision ?? 0) < Int64.max - 1 else { throw RepositoryError.invalidOrder }
        let state = UserStateChange(resetGeneration: metadata.generation.id, inboxCardID: inbox, replacementMode: replacementMode,
            revision: (previous?.revision ?? 0) + 1,
            modifiedAt: max(now, (previous?.modifiedAt ?? metadata.generation.modifiedAt).addingTimeInterval(0.001)), deviceID: try deviceID())
        metadata.authoritativeUserState = state
        metadata.replacementExpectedInboxID = inbox.rawValue
        if !replacementMode { metadata.replacementInitialDeliveryComplete = true }
        try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        try appendChange(entity: .userState, id: metadata.generation.id, payload: JSONEncoder().encode(state), now: now)
    }

    private func repairInbox(now: Date, preferred: CardID? = nil, replicateChanges: Bool = true) throws {
        let active = try cards(scope: .active)
        guard !active.isEmpty else { _ = try insertCard(title: PetalStrings.text("ui.inbox.94835e"), isInbox: true, now: now); return }
        let flagged = active.filter(\.isInbox)
        let chosen = active.first { $0.id == preferred } ?? (flagged.isEmpty ? active : flagged).min { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }!
        for var card in try cards(scope: .all) {
            let isInbox = card.id == chosen.id
            guard card.isInbox != isInbox else { continue }
            card.isInbox = isInbox
            if replicateChanges { try saveCard(card, stored: storedCard(card.id), now: now) }
            else {
                // Ordered user state owns this role. Projecting it must not
                // fabricate a newer content edit on another device's card.
                try storedCard(card.id).payload = JSONEncoder().encode(card)
            }
        }
    }

    private func discardSupersededDeletion(entity: OutboxChange.Entity, id: UUID) throws {
        // Called only after generation/tombstone checks accept an inbound
        // restoration. Never upload an older redaction over that winner.
        for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) {
            let value = try row.value()
            if value.entity == entity && value.entityID == id && value.operation == .delete { context.delete(row) }
        }
    }

    private func removeEntity(_ entity: SyncTombstone.Entity, id: UUID) throws {
        var removed = Set<UUID>([id])
        if entity == .card {
            for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>()) where row.id == id { context.delete(row) }
        }
        for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()) where (entity == .card && row.cardID == id) || (entity == .line && row.id == id) {
            removed.insert(row.id); context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) where try removed.contains(row.value().entityID) {
            context.delete(row)
        }
    }

    private func quarantine<T: Encodable>(_ value: T, cardID: CardID, lineID: LineID?, reason: StructuralIssue, now: Date) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = try? encoder.encode(value)
        // Preserve safely decoded user-visible content only within a fixed
        // budget. Otherwise identity + reason on the artifact are sufficient.
        let payload = encoded.flatMap { $0.count <= 65_536 ? $0 : nil } ?? Data()
        guard try !conflicts().contains(where: { $0.cardID == cardID && $0.lineID == lineID
            && $0.inboundIssue == reason && $0.losingPayload == payload && $0.expiresAt > now }) else { return }
        context.insert(try PetalSchemaV1.StoredConflictArtifact(ConflictArtifact(id: UUID(), cardID: cardID,
            lineID: lineID, losingPayload: payload, capturedAt: now, expiresAt: now.addingTimeInterval(2_592_000),
            hasBeenPresented: false, inboundIssue: reason)))
    }

    private func mergeDecision<T: Encodable & Equatable>(entity: OutboxChange.Entity, id: UUID,
        cardID: CardID, lineID: LineID?, local: T, remote: T, localDate: Date, remoteDate: Date,
        localDevice: String, remoteDevice: String, userVisibleDifference: Bool, now: Date) throws -> Bool {
        guard local != remote else { return false }
        let remoteWins = SyncConflictResolver.remoteWins(localDate: localDate, localDevice: localDevice, remoteDate: remoteDate, remoteDevice: remoteDevice)
        let pending = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()).filter {
            let value = try $0.value()
            return value.entity == entity && value.entityID == id
        }
        if !pending.isEmpty && localDevice != remoteDevice && userVisibleDifference {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let losing = try encoder.encode(remoteWins ? local : remote)
            if try !conflicts().contains(where: { $0.losingPayload == losing && $0.expiresAt > now }) {
                let artifact = ConflictArtifact(id: UUID(), cardID: cardID, lineID: lineID,
                    losingPayload: losing, capturedAt: now, expiresAt: now.addingTimeInterval(2_592_000), hasBeenPresented: false)
                context.insert(try PetalSchemaV1.StoredConflictArtifact(artifact))
            }
        }
        if remoteWins { for row in pending { context.delete(row) } }
        return remoteWins
    }

    func takeUnpresentedConflicts(now: Date) throws -> [ConflictArtifact] {
        try transaction(notify: false) {
            var result: [ConflictArtifact] = []
            for row in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()) {
                var value = try row.value()
                if value.expiresAt > now && !value.hasBeenPresented {
                    result.append(value)
                    value.hasBeenPresented = true
                    row.payload = try JSONEncoder().encode(value)
                }
            }
            return result
        }
    }

    func recordSyncState(_ state: SyncState, retryAt: Date?, expectedEpoch: UInt64? = nil) throws {
        try transaction(notify: false) {
            var metadata = try syncMetadata()
            try validateSyncEpoch(expectedEpoch, metadata)
            if case .failed(.other) = state { metadata.state = .failed(.other("sync-unavailable")) }
            else { metadata.state = state }
            metadata.retryAt = retryAt
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    private func appendChange(entity: OutboxChange.Entity, id: UUID, payload: Data, now: Date,
                              operation: OutboxChange.Operation = .upsert) throws {
        let state = try userState()
        guard state.nextOutboxSequence < Int64.max else { throw RepositoryError.invalidOrder }
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
            let index = try insertionIndex(cardID: draft.cardID, count: 1, now: now)
            return try insertLine(draft, sortIndex: index, now: now)
        }
    }

    func captureTodoLines(cardID: CardID, texts: [String], now: Date) throws -> [CardLine] {
        try transaction {
            guard try cards(scope: .all).contains(where: { $0.id == cardID && $0.status == .active }) else {
                throw RepositoryError.cardUnavailable
            }
            let nonempty = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let index = try insertionIndex(cardID: cardID, count: nonempty.count, now: now)
            return try nonempty.enumerated().map { offset, text in
                let (position, overflow) = index.addingReportingOverflow(Int64(offset))
                guard !overflow else { throw RepositoryError.invalidOrder }
                return try insertLine(NewLineDraft(cardID: cardID, kind: .todo, text: text), sortIndex: position, now: now)
            }
        }
    }

    private func insertionIndex(cardID: CardID, count: Int, now: Date) throws -> Int64 {
        let existing = try lines(cardID: cardID)
        let maximum = existing.map(\.sortIndex).max() ?? -1
        let (end, overflow) = maximum.addingReportingOverflow(Int64(count))
        if !overflow, maximum >= -1, end < Int64.max - 1,
           existing.allSatisfy({ $0.sortIndex >= 0 }) { return maximum + 1 }
        // Reindex in the insertion transaction, preserving deterministic manual
        // order. Any failure rolls back both reindexing and all inserted rows.
        for (index, line) in existing.enumerated() where line.sortIndex != Int64(index) {
            var value = line; value.sortIndex = Int64(index)
            try saveLine(value, stored: storedLine(line.id), now: now)
        }
        return Int64(existing.count)
    }

    private func insertLine(_ draft: NewLineDraft, sortIndex: Int64, now: Date) throws -> CardLine {
        try draft.reminder?.validate()
        let completed = draft.kind == .todo && draft.isCompleted
        var value = CardLine(id: LineID(rawValue: UUID()), cardID: draft.cardID, kind: draft.kind,
                             text: draft.text, sortIndex: sortIndex, isCompleted: completed,
                             completedAt: completed ? now : nil, lastDailyCompletionKey: nil,
                             dailyStreak: 0, reminder: draft.kind == .todo ? draft.reminder : nil,
                             createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: try deviceID())
        if completed, case .daily = value.reminder?.rule {
            value.lastDailyCompletionKey = CompletionPolicy.localDayKey(for: now, calendar: .current)
            value.dailyStreak = 1
        }
        let stored = try PetalSchemaV1.StoredLine(value)
        context.insert(stored)
        try appendChange(entity: .line, id: stored.id, payload: stored.payload, now: now)
        return value
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
        guard updated.revision < Int64.max - 1 else { throw RepositoryError.invalidOrder }
        updated.revision += 1
        updated.modifiedAt = now
        updated.deviceID = try deviceID()
        stored.payload = try JSONEncoder().encode(updated)
        try appendChange(entity: .line, id: stored.id, payload: stored.payload, now: now)
    }

    func updateLine(_ mutation: LineMutation, now: Date) throws -> CardLine {
        try mutation.reminder?.validate()
        return try transaction {
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

    func deleteLine(lineID: LineID, now: Date) throws {
        try transaction {
            let stored = try storedLine(lineID)
            try appendDeletion(entity: .line, id: stored.id, now: now)
            context.delete(stored)
        }
    }

    func setWidgetCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) throws {
        try transaction {
            let stored = try storedLine(lineID)
            var value = try stored.value()
            guard value.kind == .todo else { throw RepositoryError.lineUnavailable }
            guard try cards(scope: .active).contains(where: { $0.id == value.cardID }) else {
                throw RepositoryError.cardUnavailable
            }
            guard applyCompletion(&value, completed: completed, now: now, calendar: calendar) else { return }
            try saveLine(value, stored: stored, now: now)
        }
    }

    func setReminder(lineID: LineID, reminder: Reminder?, now: Date) throws -> CardLine {
        try reminder?.validate()
        return try transaction {
            let stored = try storedLine(lineID)
            var value = try stored.value()
            guard value.kind == .todo else { throw RepositoryError.lineUnavailable }
            guard value.reminder != reminder else { return value }
            value.reminder = reminder
            try saveLine(value, stored: stored, now: now)
            return try stored.value()
        }
    }

    func setCompleted(lineID: LineID, completed: Bool, now: Date) throws {
        try transaction {
            let stored = try storedLine(lineID)
            var value = try stored.value()
            guard value.kind == .todo else { throw RepositoryError.lineUnavailable }
            guard applyCompletion(&value, completed: completed, now: now, calendar: .current) else { return }
            try saveLine(value, stored: stored, now: now)
        }
    }

    /// Both completion commands use this inside their existing transaction, so
    /// snooze cancellation and completion share one revision/outbox payload.
    private func applyCompletion(_ value: inout CardLine, completed: Bool, now: Date, calendar: Calendar) -> Bool {
        let effectiveCompleted = CompletionPolicy.isCompleted(value, now: now, calendar: calendar)
        let stateChanged = effectiveCompleted != completed
        let clearsSnooze = completed && value.reminder?.snoozedUntil != nil
        guard stateChanged || clearsSnooze else { return false }
        if stateChanged {
            if case .daily = value.reminder?.rule {
                let today = CompletionPolicy.localDayKey(for: now, calendar: calendar)
                let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map {
                    CompletionPolicy.localDayKey(for: $0, calendar: calendar)
                }
                if completed {
                    let previous = value.completedAt.map { CompletionPolicy.localDayKey(for: $0, calendar: calendar) }
                        ?? value.lastDailyCompletionKey
                    let continuous = previous != nil && previous == yesterday
                    value.dailyStreak = continuous ? (value.dailyStreak < Int.max ? value.dailyStreak + 1 : Int.max) : 1
                    value.lastDailyCompletionKey = today
                } else {
                    // Undo removes today's credit. A consecutive streak keeps
                    // yesterday's credit, allowing a same-day redo without inflation.
                    value.dailyStreak = max(0, value.dailyStreak - 1)
                    value.lastDailyCompletionKey = value.dailyStreak > 0 ? yesterday : nil
                }
            }
            value.isCompleted = completed
            value.completedAt = completed ? now : nil
        }
        if completed { value.reminder?.snoozedUntil = nil }
        return true
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
        guard updated.revision < Int64.max - 1 else { throw RepositoryError.invalidOrder }
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
            let wasInbox = value.isInbox
            guard value.status != status else { return }
            if value.isInbox && status != .active {
                let candidates = try cards(scope: .active).filter { $0.id != id }
                let selected = replacementInbox ?? (createReplacement && candidates.count == 1 ? candidates[0].id : nil)
                if let selected, let replacementValue = candidates.first(where: { $0.id == selected }) {
                    var replacement = replacementValue
                    replacement.isInbox = true
                    try saveCard(replacement, stored: storedCard(selected), now: now)
                } else if selected == nil && createReplacement && candidates.isEmpty {
                    _ = try insertCard(title: PetalStrings.text("ui.inbox.94835e"), isInbox: true, now: now)
                } else {
                    throw RepositoryError.replacementInboxRequired
                }
                value.isInbox = false
            }
            value.status = status
            value.archivedAt = status == .archived ? now : nil
            value.deletedAt = status == .trashed ? now : nil
            try saveCard(value, stored: stored, now: now)
            let metadata = try syncMetadata()
            if wasInbox && metadata.generation.isReplacement && metadata.replacementPlaceholderID == nil,
               let inbox = try cards(scope: .active).first(where: \.isInbox) {
                try publishCurrentInbox(inbox.id, replacementMode: false, now: now)
            }
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

    func recoverConflict(id: UUID, now: Date) throws -> CardID {
        try transaction {
            guard let row = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()).first(where: { $0.id == id }),
                  var artifact = try? row.value(), artifact.expiresAt > now else { throw RepositoryError.lineUnavailable }
            if let recovered = artifact.recoveredCardID, try cards(scope: .all).contains(where: { $0.id == recovered }) {
                return recovered
            }
            let decoder = JSONDecoder()
            let copy: Card
            if artifact.lineID != nil {
                let source = try decoder.decode(CardLine.self, from: artifact.losingPayload)
                try DomainStructure.validate(source)
                let title = try cards(scope: .all).first(where: { $0.id == artifact.cardID })?.title
                    ?? PetalStrings.text("ui.inbox.94835e")
                copy = try insertCard(title: title, isInbox: false, now: now)
                let line = CardLine(id: LineID(rawValue: UUID()), cardID: copy.id, kind: source.kind, text: source.text,
                    sortIndex: 0, isCompleted: source.isCompleted, completedAt: source.completedAt,
                    lastDailyCompletionKey: source.lastDailyCompletionKey, dailyStreak: source.dailyStreak,
                    reminder: source.reminder, createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: try deviceID())
                let stored = try PetalSchemaV1.StoredLine(line)
                context.insert(stored)
                try appendChange(entity: .line, id: stored.id, payload: stored.payload, now: now)
            } else {
                let source = try decoder.decode(Card.self, from: artifact.losingPayload)
                try DomainStructure.validate(source)
                var card = try insertCard(title: source.title, isInbox: false, now: now)
                card.themeID = source.themeID
                try saveCard(card, stored: storedCard(card.id), now: now)
                copy = card
            }
            artifact.recoveredCardID = copy.id
            row.payload = try JSONEncoder().encode(artifact)
            return copy.id
        }
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
        if entity == .card || entity == .line {
            var metadata = try syncMetadata()
            guard try userState().nextOutboxSequence < Int64.max else { throw RepositoryError.invalidOrder }
            metadata.tombstones.removeAll { $0.entityID == id }
            metadata.tombstones.append(SyncTombstone(id: UUID(), entity: entity == .card ? .card : .line,
                entityID: id, deletedAt: now, deviceID: try deviceID(), revision: try userState().nextOutboxSequence + 1))
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
        // Retention also applies to queued snapshots: never keep expired user content
        // in an earlier upsert or in a redaction's payload.
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
            let previous = try syncMetadata().generation
            // A backwards wall clock cannot make a local reset older than one already observed.
            let date = max(now, previous.modifiedAt.addingTimeInterval(0.001))
            try resetContents(generation: ResetGeneration(id: resetGeneration, modifiedAt: date, deviceID: try deviceID()), now: now)
        }
    }

    private func resetContents(generation: ResetGeneration, now: Date, replacement: TransferSnapshot? = nil) throws {
            // Install the content-free cross-process fence before mutation. A
            // failed transaction may discard cached display, never canonical data.
            try coordinator.installWidgetResetFence(generation: generation.id)
            resetFenceInstalled = true
            let oldCards = try cards(scope: .all)
            let waitingLines = try (syncMetadata().unresolvedLines ?? []).compactMap { record -> CardLine? in
                if case .line(let line) = record.payload { return line }; return nil
            }
            let oldLines = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).map { try $0.value() } + waitingLines
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredImportFingerprint>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()) { context.delete(value) }
            let state: PetalSchemaV1.StoredUserState
            if let existing = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredUserState>()).first {
                state = existing
                state.resetGeneration = generation.id
            } else {
                state = PetalSchemaV1.StoredUserState(resetGeneration: generation.id)
                context.insert(state)
            }
            var metadata = try syncMetadata()
            metadata.generation = generation
            if !generation.isReplacement {
                metadata.erasureFence = generation
                metadata.erasureScanGeneration = generation.id
                metadata.token = nil
            } else if metadata.erasureScanGeneration != nil {
                // A restore before the pending erasure completes must not
                // discard the obligation to inspect older generations.
                metadata.token = nil
            }
            metadata.onboardingCompleted = true
            metadata.unresolvedLines = nil
            metadata.resetCleanupPending = true
            metadata.replacementPlaceholderID = nil
            metadata.replacementExpectedInboxID = nil
            metadata.authoritativeUserState = nil
            metadata.replacementInitialDeliveryComplete = nil
            metadata.replacementInitialInboxIDs = nil
            metadata.replacementDeliveryStatus = nil
            if generation.isReplacement {
                metadata.tombstones = []
                try syncMetadataRow().payload = JSONEncoder().encode(metadata)
                if let replacement {
                    var cards = replacement.cards
                    let active = cards.filter { $0.status == .active }
                    let inboxID = (active.first(where: \.isInbox) ?? active.min { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString })?.id
                        ?? CardID(rawValue: generation.id)
                    metadata.replacementExpectedInboxID = inboxID.rawValue
                    try syncMetadataRow().payload = JSONEncoder().encode(metadata)
                    if active.isEmpty {
                        cards.append(Card(id: inboxID, title: PetalStrings.text("ui.inbox.94835e"), status: .active, themeID: .cream, isInbox: true,
                            createdAt: generation.modifiedAt, modifiedAt: generation.modifiedAt, archivedAt: nil,
                            deletedAt: nil, revision: 1, deviceID: generation.deviceID))
                    }
                    try publishCurrentInbox(inboxID, replacementMode: true, now: generation.modifiedAt)
                    for var card in cards {
                        card.isInbox = card.id == inboxID
                        card.deviceID = generation.deviceID; card.revision = 1; card.modifiedAt = generation.modifiedAt
                        let row = try PetalSchemaV1.StoredCard(card); context.insert(row)
                        try appendChange(entity: .card, id: row.id, payload: row.payload, now: now)
                    }
                    for var line in replacement.lines {
                        line.deviceID = generation.deviceID; line.revision = 1; line.modifiedAt = generation.modifiedAt
                        let row = try PetalSchemaV1.StoredLine(line); context.insert(row)
                        try appendChange(entity: .line, id: row.id, payload: row.payload, now: now)
                    }
                } else {
                    let card = Card(id: CardID(rawValue: generation.id), title: PetalStrings.text("ui.inbox.94835e"), status: .active, themeID: .cream,
                        isInbox: true, createdAt: generation.modifiedAt, modifiedAt: generation.modifiedAt,
                        archivedAt: nil, deletedAt: nil, revision: 1, deviceID: generation.deviceID)
                    context.insert(try PetalSchemaV1.StoredCard(card))
                    metadata.replacementPlaceholderID = generation.id
                    try syncMetadataRow().payload = JSONEncoder().encode(metadata)
                }
                return
            }
            // Defensive normalization for development stores written before
            // inbound identity validation; malformed duplicates must never trap.
            var tombstones: [UUID: SyncTombstone] = [:]
            for value in metadata.tombstones {
                if let previous = tombstones[value.entityID], previous.deletedAt > value.deletedAt { continue }
                tombstones[value.entityID] = value
            }
            for card in oldCards {
                tombstones[card.id.rawValue] = SyncTombstone(id: tombstones[card.id.rawValue]?.id ?? UUID(),
                    entity: .card, entityID: card.id.rawValue, deletedAt: generation.modifiedAt,
                    deviceID: generation.deviceID, revision: card.revision == .max ? .max : card.revision + 1)
            }
            for line in oldLines {
                tombstones[line.id.rawValue] = SyncTombstone(id: tombstones[line.id.rawValue]?.id ?? UUID(),
                    entity: .line, entityID: line.id.rawValue, deletedAt: generation.modifiedAt,
                    deviceID: generation.deviceID, revision: line.revision == .max ? .max : line.revision + 1)
            }
            metadata.tombstones = tombstones.values.sorted { $0.id.uuidString < $1.id.uuidString }
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            for tombstone in metadata.tombstones {
                try appendChange(entity: tombstone.entity == .card ? .card : .line, id: tombstone.entityID,
                    payload: Data(), now: now, operation: .delete)
            }
            let inbox = try insertCard(title: PetalStrings.text("ui.inbox.94835e"), isInbox: true, now: generation.modifiedAt, id: generation.id)
            let payload = try JSONEncoder().encode(UserStateChange(resetGeneration: generation.id, inboxCardID: inbox.id))
            try appendChange(entity: .userState, id: generation.id, payload: payload, now: now)
    }

    func cards(scope: CardScope) throws -> [Card] {
        try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>())
            .map { try $0.value() }
            .filter { scope == .all || $0.status.rawValue == scope.rawValue }
            .sorted { $0.createdAt == $1.createdAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.createdAt < $1.createdAt }
    }
}
