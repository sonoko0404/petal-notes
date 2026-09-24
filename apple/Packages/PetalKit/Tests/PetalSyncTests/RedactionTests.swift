import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private let redactionNow = Date(timeIntervalSince1970: 1_800_000_000)

// Only the external server is faked: production mapper, engine buffer,
// system-field archives, repository merge, checkpoint and outbox are exercised.
private struct TaggedServer {
    var records: [CKRecord.ID: CKRecord] = [:]
    var sequence = 0
    mutating func seed(_ record: CKRecord) throws {
        sequence += 1
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive)
        archive.encode("tag-\(sequence)", forKey: "fixtureTag"); archive.finishEncoding()
        var plist = try #require(PropertyListSerialization.propertyList(from: archive.encodedData, format: nil) as? [String: Any])
        var top = try #require(plist["$top"] as? [String: Any])
        top["ETag"] = top.removeValue(forKey: "fixtureTag"); plist["$top"] = top
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data); decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        let tagged = try #require(CKRecord(coder: decoder))
        for key in record.allKeys() { tagged[key] = record[key] }
        records[record.recordID] = tagged
    }
    mutating func send(_ plan: PreparedEngineSend, buffer: inout EngineEventBuffer) throws {
        let conflicts = plan.records.filter { candidate in
            if let current = records[candidate.recordID] { return candidate.recordChangeTag != current.recordChangeTag }
            return candidate.recordChangeTag != nil
        }
        if !conflicts.isEmpty {
            buffer.didSend(savedRecords: [], deletedRecordIDs: [], failures: plan.records.map { record in
                let current = records[record.recordID]
                let code: CKError.Code = conflicts.contains { $0.recordID == record.recordID }
                    ? (current == nil ? .unknownItem : .serverRecordChanged) : .batchRequestFailed
                return .save(record, CKError(code, userInfo: current.map { [CKRecordChangedErrorServerRecordKey: $0] } ?? [:]))
            })
            return
        }
        for record in plan.records { try seed(record) }
        for id in plan.deletions.values { records.removeValue(forKey: id) }
        buffer.didSend(savedRecords: plan.records.compactMap { records[$0.recordID] }, deletedRecordIDs: Array(plan.deletions.values), failures: [])
    }
}

@Test(arguments: [false, true])
func delayedDeletionCannotEraseNewerSharedServerContent(replacement: Bool) async throws {
    let a = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let b = try open()
    let card = try await a.createCard(title: "Original", now: redactionNow)
    let initial = try #require(CloudRecordMapper.outbound(await a.syncSnapshot()).first).record
    var server = TaggedServer()
    try server.seed(CloudRecordMapper.encode(initial))
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive(Array(server.records.values))
    try await b.applyInbound(buffer.fetchResult().records, token: buffer.checkpoint(), now: redactionNow)
    try await b.moveCardEnsuringInbox(card.id, to: .trashed, replacementInbox: nil, now: redactionNow)
    let later = redactionNow.addingTimeInterval(2_592_001)
    try await b.purgeExpiredTrash(now: later)
    let deletion = try #require(CloudRecordMapper.outbound(await b.syncSnapshot()).first { $0.journal.last?.operation == .delete })
    buffer.beginSend()
    let delayed = try buffer.prepareSend([deletion.record])
    // A wins after B prepares its old-generation intent and cached change tag.
    if replacement { try await a.replaceUserData(a.transferSnapshot(), now: later) }
    else { _ = try await a.updateCardTitle(card.id, title: "Newer content", now: later.addingTimeInterval(2_592_001)) }
    let winner = try #require(CloudRecordMapper.outbound(await a.syncSnapshot()).first { $0.journal.last?.entityID == card.id.rawValue }).record
    for change in try await CloudRecordMapper.outbound(a.syncSnapshot()) { try server.seed(CloudRecordMapper.encode(change.record)) }
    try server.send(delayed, buffer: &buffer)
    #expect(throws: CloudTransportError.conflict) { try buffer.sendResult() }
    #expect(try await b.pendingOutbox().contains { $0.id == deletion.id })
    let target = CKRecord.ID(recordName: card.id.rawValue.uuidString, zoneID: CloudRecordMapper.zoneID)
    #expect(try server.records[target].map(CloudRecordMapper.decode) == winner)
    // Restart retains the unacknowledged intent until a fresh fetch decides it.
    let reopened = try open()
    var fresh = try EngineEventBuffer(checkpoint: await reopened.syncSnapshot().token)
    try fresh.receive(Array(server.records.values))
    try await reopened.applyInbound(fresh.fetchResult().records, token: fresh.checkpoint(), now: later.addingTimeInterval(2_592_002))
    #expect(try await reopened.card(id: card.id)?.title == (replacement ? "Original" : "Newer content"))
    #expect(try !CloudRecordMapper.outbound(await reopened.syncSnapshot()).contains { $0.id == deletion.id })
}

@Test func winningRedactionErasesPayloadAndRestorationExplicitlyClearsDeletedFlag() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Sensitive fixture", now: redactionNow)
    let live = ReplicatedRecord(payload: .card(card), generation: .initial)
    var server = TaggedServer()
    try server.seed(CloudRecordMapper.encode(live))
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive(Array(server.records.values)); buffer.beginSend()
    let tombstone = SyncTombstone(id: UUID(), entity: .card, entityID: card.id.rawValue,
        deletedAt: redactionNow, deviceID: "B", revision: 2)
    let deletion = ReplicatedRecord(payload: .tombstone(tombstone), generation: .initial)
    let plan = try buffer.prepareSend([deletion])
    try server.send(plan, buffer: &buffer)
    #expect(try buffer.sendResult().savedRecordIDs == [card.id.rawValue])
    let redacted = try #require(server.records.values.first)
    #expect(try CloudRecordMapper.decode(redacted) == deletion)
    #expect(!String(decoding: try #require(redacted["payload"] as? Data), as: UTF8.self).contains("Sensitive"))
    var reopened = try EngineEventBuffer(checkpoint: buffer.checkpoint())
    reopened.beginSend()
    let restored = try reopened.prepare(live)
    // Exercise CK changed-key replacement, including explicit isDeleted = 0.
    for key in restored.changedKeys() { redacted[key] = restored[key] }
    #expect(try CloudRecordMapper.decode(redacted) == live)
}

@Test func permanentDeletionSavesContentFreeEntityFenceInsteadOfPhysicalDelete() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await repository.createCard(title: "Private title", now: redactionNow)
    _ = try await repository.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Private line"), now: redactionNow)
    try await repository.deleteAllData(resetGeneration: UUID(), now: redactionNow.addingTimeInterval(1))
    let deletions = try await CloudRecordMapper.outbound(repository.syncSnapshot()).filter { $0.journal.last?.operation == .delete }
    let buffer = try EngineEventBuffer(checkpoint: nil)
    let plan = try buffer.prepareSend(deletions.map(\.record))
    #expect(plan.deletions.isEmpty)
    #expect(Set(plan.records.map(\.recordType)) == ["PTCard", "PTLine"])
    for (change, record) in zip(deletions, plan.records) {
        #expect(record.recordID.recordName == change.journal.last?.entityID.uuidString)
        #expect(record["isDeleted"] as? Int64 == 1)
        #expect(record["redactionVersion"] as? Int64 == 1)
        #expect(try CloudRecordMapper.decode(record) == change.record)
        let payload = try #require(record["payload"] as? Data)
        #expect(!String(decoding: payload, as: UTF8.self).contains("Private"))
    }
}

@Test func redactionDecodingAcceptsLegacyFencesAndRejectsFutureRepresentation() throws {
    let tombstone = SyncTombstone(id: UUID(), entity: .card, entityID: UUID(), deletedAt: redactionNow, deviceID: "B", revision: 2)
    let value = ReplicatedRecord(payload: .tombstone(tombstone), generation: .initial)
    let redacted = try CloudRecordMapper.encode(value)
    let legacy = CKRecord(recordType: "PTTombstone", recordID: CKRecord.ID(recordName: tombstone.id.uuidString, zoneID: CloudRecordMapper.zoneID))
    for key in redacted.allKeys() where key != "isDeleted" && key != "redactionVersion" { legacy[key] = redacted[key] }
    #expect(try CloudRecordMapper.decode(legacy) == value)
    redacted["redactionVersion"] = 2 as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(redacted) }
    let card = Card(id: CardID(rawValue: UUID()), title: "Live", status: .active, themeID: .cream, isInbox: true,
        createdAt: redactionNow, modifiedAt: redactionNow, archivedAt: nil, deletedAt: nil, revision: 1, deviceID: "A")
    let live = try CloudRecordMapper.encode(ReplicatedRecord(payload: .card(card), generation: .initial))
    live["isDeleted"] = nil; live["redactionVersion"] = nil
    #expect(try CloudRecordMapper.decode(live).payload == .card(card))
    live["redactionVersion"] = 2 as CKRecordValue
    #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.decode(live) }
}
