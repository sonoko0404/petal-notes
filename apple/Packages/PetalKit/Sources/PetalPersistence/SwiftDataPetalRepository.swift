import Foundation
import SwiftData
import PetalCore

public struct SwiftDataPetalRepository: PetalSyncRepository, PetalTransferRepository {
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
    public func captureTodoLines(cardID: CardID, texts: [String], now: Date) async throws -> [CardLine] {
        try await store.captureTodoLines(cardID: cardID, texts: texts, now: now)
    }
    public func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine { try await store.updateLine(mutation, now: now) }
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
    public func purgeExpiredConflicts(now: Date) async throws { try await store.purgeExpiredConflicts(now: now) }
    public func deleteAllData(resetGeneration: UUID, now: Date) async throws {
        try await store.deleteAllData(resetGeneration: resetGeneration, now: now)
    }
    public func resetGeneration() async throws -> UUID? { try await store.resetGeneration() }
    public func syncSnapshot() async throws -> SyncSnapshot { try await store.syncSnapshot() }
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
            var cardIDs = Set(before.cards.map(\.id))
            var lineIDs = Set(before.lines.map(\.id))
            for entry in entries where !fingerprints.contains(entry.fingerprint) {
                let sourceKey = "windows-note:" + entry.sourceNoteID.uuidString.lowercased()
                guard !fingerprints.contains(sourceKey) else { continue }
                guard cardIDs.insert(entry.card.id).inserted,
                      entry.lines.allSatisfy({ lineIDs.insert($0.id).inserted && $0.cardID == entry.card.id }) else {
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
            defer { transactionContext = nil }
            do {
                let result = try body()
                if faultInjector == .failBeforeSave { throw RepositoryError.injectedFailure }
                if faultInjector == .failOnceBeforeSave {
                    faultInjector = .none
                    throw RepositoryError.injectedFailure
                }
                let changed = session.hasChanges
                try session.save()
                if notify && changed { NotificationCenter.default.post(name: .petalRepositoryDidCommit, object: nil) }
                return result
            } catch {
                session.rollback()
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
            metadata.resetCleanupPending = false
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
        }
    }

    func syncSnapshot() throws -> SyncSnapshot {
        try coordinator.withLock {
            SyncSnapshot(enabled: try syncMetadata().enabled, changes: try pendingOutbox(), token: try syncMetadata().token,
                         tombstones: try syncMetadata().tombstones, generation: try syncMetadata().generation,
                         state: try syncMetadata().state, retryAt: try syncMetadata().retryAt,
                         preferenceEpoch: try syncMetadata().preferenceEpoch ?? 0)
        }
    }

    private func validateSyncEpoch(_ expected: UInt64?, _ metadata: LocalSyncMetadata) throws {
        if let expected, !metadata.enabled || expected != (metadata.preferenceEpoch ?? 0) {
            throw RepositoryError.syncSessionSuperseded
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
            let received = (metadata.unresolvedLines ?? []) + records
            if let latest = received.map(\.generation).max(), latest > metadata.generation {
                try resetContents(generation: latest, now: now)
                metadata = try syncMetadata()
            }
            // A reset also cleans up stale records first discovered after the
            // local reset. The cleanup survives another offline failure.
            for record in received where record.generation < metadata.generation && !metadata.generation.isReplacement {
                let entity: SyncTombstone.Entity
                let id: UUID
                switch record.payload {
                case .card(let card): entity = .card; id = card.id.rawValue
                case .line(let line): entity = .line; id = line.id.rawValue
                default: continue
                }
                if !metadata.tombstones.contains(where: { $0.entity == entity && $0.entityID == id }) {
                    metadata.tombstones.append(SyncTombstone(id: UUID(), entity: entity, entityID: id,
                        deletedAt: metadata.generation.modifiedAt, deviceID: metadata.generation.deviceID, revision: 1))
                    try appendChange(entity: entity == .card ? .card : .line, id: id, payload: Data(), now: now, operation: .delete)
                }
            }
            let records = received.filter { $0.generation == metadata.generation }.sorted {
                func rank(_ value: ReplicatedRecord) -> Int {
                    switch value.payload { case .userState: 0; case .tombstone: 1; case .card: 2; case .line: 3 }
                }
                return rank($0) < rank($1)
            }
            let restoredInbox = records.compactMap { record -> CardID? in
                if case .card(let card) = record.payload, card.status == .active && card.isInbox { return card.id }
                return nil
            }.first
            let preferredInbox = metadata.replacementPlaceholderID != nil ? restoredInbox : nil
            if let placeholder = metadata.replacementPlaceholderID, restoredInbox != nil {
                // A marker-only page gets a local, never-uploaded placeholder.
                // Remove it when real replacement content arrives. Captures made
                // while waiting remain as a normal card rather than losing edits.
                let placeholderCard = try cards(scope: .all).first { $0.id.rawValue == placeholder }
                let hasChildren = try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).contains {
                    try $0.value().cardID.rawValue == placeholder
                }
                let hasPendingEdits = try pendingOutbox().contains { $0.entityID == placeholder }
                if placeholderCard?.revision == 1 && !hasChildren && !hasPendingEdits {
                    try removeEntity(.card, id: placeholder)
                } else if var card = placeholderCard {
                    card.isInbox = false
                    try saveCard(card, stored: storedCard(card.id), now: now)
                }
                metadata.replacementPlaceholderID = nil
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
                case .line(let line):
                    if metadata.tombstones.contains(where: {
                        ($0.entity == .line && $0.entityID == line.id.rawValue || $0.entity == .card && $0.entityID == line.cardID.rawValue)
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
                case .tombstone, .userState: break
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
            metadata.token = token
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            try repairInbox(now: now, preferred: preferredInbox)
        }
    }

    private func repairInbox(now: Date, preferred: CardID? = nil) throws {
        let active = try cards(scope: .active)
        guard !active.isEmpty else { _ = try insertCard(title: "Inbox", isInbox: true, now: now); return }
        let flagged = active.filter(\.isInbox)
        let chosen = active.first { $0.id == preferred } ?? (flagged.isEmpty ? active : flagged).min { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }!
        for var card in try cards(scope: .all) {
            let isInbox = card.id == chosen.id
            guard card.isInbox != isInbox else { continue }
            card.isInbox = isInbox
            try saveCard(card, stored: storedCard(card.id), now: now)
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
            return try insertLine(draft, sortIndex: index, now: now)
        }
    }

    func captureTodoLines(cardID: CardID, texts: [String], now: Date) throws -> [CardLine] {
        try transaction {
            guard try cards(scope: .all).contains(where: { $0.id == cardID && $0.status == .active }) else {
                throw RepositoryError.cardUnavailable
            }
            let nonempty = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var index = try (lines(cardID: cardID).map(\.sortIndex).max() ?? -1) + 1
            return try nonempty.map { text in
                defer { index += 1 }
                return try insertLine(NewLineDraft(cardID: cardID, kind: .todo, text: text), sortIndex: index, now: now)
            }
        }
    }

    private func insertLine(_ draft: NewLineDraft, sortIndex: Int64, now: Date) throws -> CardLine {
        try draft.reminder?.validate()
        let completed = draft.kind == .todo && draft.isCompleted
        let value = CardLine(id: LineID(rawValue: UUID()), cardID: draft.cardID, kind: draft.kind,
                             text: draft.text, sortIndex: sortIndex, isCompleted: completed,
                             completedAt: completed ? now : nil, lastDailyCompletionKey: nil,
                             dailyStreak: 0, reminder: draft.kind == .todo ? draft.reminder : nil,
                             createdAt: now, modifiedAt: now, deletedAt: nil, revision: 1, deviceID: try deviceID())
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

    func setWidgetCompleted(lineID: LineID, completed: Bool, now: Date, calendar: Calendar) throws {
        try transaction {
            let stored = try storedLine(lineID)
            var value = try stored.value()
            guard value.kind == .todo else { throw RepositoryError.lineUnavailable }
            guard try cards(scope: .active).contains(where: { $0.id == value.cardID }) else {
                throw RepositoryError.cardUnavailable
            }
            var effectiveCompleted = value.isCompleted
            if case .daily = value.reminder?.rule, let date = value.completedAt,
               !calendar.isDate(date, inSameDayAs: now) { effectiveCompleted = false }
            guard applyCompletion(&value, completed: completed, effectiveCompleted: effectiveCompleted, now: now) else { return }
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
            guard applyCompletion(&value, completed: completed, effectiveCompleted: value.isCompleted, now: now) else { return }
            try saveLine(value, stored: stored, now: now)
        }
    }

    /// Both completion commands use this inside their existing transaction, so
    /// snooze cancellation and completion share one revision/outbox payload.
    private func applyCompletion(_ value: inout CardLine, completed: Bool, effectiveCompleted: Bool, now: Date) -> Bool {
        let stateChanged = effectiveCompleted != completed
        let clearsSnooze = completed && value.reminder?.snoozedUntil != nil
        guard stateChanged || clearsSnooze else { return false }
        if stateChanged {
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
        if entity == .card || entity == .line {
            var metadata = try syncMetadata()
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
            metadata.unresolvedLines = nil
            metadata.resetCleanupPending = true
            metadata.replacementPlaceholderID = nil
            if generation.isReplacement {
                metadata.tombstones = []
                try syncMetadataRow().payload = JSONEncoder().encode(metadata)
                if let replacement {
                    var cards = replacement.cards
                    let active = cards.filter { $0.status == .active }
                    let inboxID = (active.first(where: \.isInbox) ?? active.min { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString })?.id
                        ?? CardID(rawValue: generation.id)
                    if active.isEmpty {
                        cards.append(Card(id: inboxID, title: "Inbox", status: .active, themeID: .cream, isInbox: true,
                            createdAt: generation.modifiedAt, modifiedAt: generation.modifiedAt, archivedAt: nil,
                            deletedAt: nil, revision: 1, deviceID: generation.deviceID))
                    }
                    let payload = try JSONEncoder().encode(UserStateChange(resetGeneration: generation.id, inboxCardID: inboxID))
                    try appendChange(entity: .userState, id: generation.id, payload: payload, now: now)
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
                    let card = Card(id: CardID(rawValue: generation.id), title: "Inbox", status: .active, themeID: .cream,
                        isInbox: true, createdAt: generation.modifiedAt, modifiedAt: generation.modifiedAt,
                        archivedAt: nil, deletedAt: nil, revision: 1, deviceID: generation.deviceID)
                    context.insert(try PetalSchemaV1.StoredCard(card))
                    metadata.replacementPlaceholderID = generation.id
                    try syncMetadataRow().payload = JSONEncoder().encode(metadata)
                }
                return
            }
            var tombstones = Dictionary(uniqueKeysWithValues: metadata.tombstones.map { ($0.entityID, $0) })
            for card in oldCards {
                tombstones[card.id.rawValue] = SyncTombstone(id: tombstones[card.id.rawValue]?.id ?? UUID(),
                    entity: .card, entityID: card.id.rawValue, deletedAt: generation.modifiedAt,
                    deviceID: generation.deviceID, revision: card.revision + 1)
            }
            for line in oldLines {
                tombstones[line.id.rawValue] = SyncTombstone(id: tombstones[line.id.rawValue]?.id ?? UUID(),
                    entity: .line, entityID: line.id.rawValue, deletedAt: generation.modifiedAt,
                    deviceID: generation.deviceID, revision: line.revision + 1)
            }
            metadata.tombstones = tombstones.values.sorted { $0.id.uuidString < $1.id.uuidString }
            try syncMetadataRow().payload = JSONEncoder().encode(metadata)
            for tombstone in metadata.tombstones {
                try appendChange(entity: tombstone.entity == .card ? .card : .line, id: tombstone.entityID,
                    payload: Data(), now: now, operation: .delete)
            }
            let inbox = try insertCard(title: "Inbox", isInbox: true, now: generation.modifiedAt, id: generation.id)
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
