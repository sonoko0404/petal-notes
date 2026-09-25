import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

@Test(arguments: ["json", "uuid", "oversize", "redactionShape"])
func undecodableCloudPayloadIsMetadataOnlyQuarantineAndDoesNotBlockPage(kind: String) async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await sender.createCard(title: "Valid page content", now: now)
    let valid = try CloudRecordMapper.encode(ReplicatedRecord(payload: .card(card), generation: .initial))
    let bad = try CloudRecordMapper.encode(ReplicatedRecord(payload: .card(card), generation: .initial))
    switch kind {
    case "oversize": bad["payload"] = Data(repeating: 65, count: 1_048_577) as CKRecordValue
    case "redactionShape": bad["isDeleted"] = 1 as CKRecordValue
    case "uuid":
        let json = String(decoding: try #require(bad["payload"] as? Data), as: UTF8.self)
        bad["payload"] = Data(json.replacingOccurrences(of: card.id.rawValue.uuidString, with: "invalid-id").utf8) as CKRecordValue
    default: bad["payload"] = Data("private undecodable bytes".utf8) as CKRecordValue
    }
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([bad, valid])
    let fetched = try buffer.fetchResult()
    for record in fetched.records {
        if case .invalidInbound = record.payload {
            #expect(throws: CloudTransportError.invalidRecord) { try CloudRecordMapper.encode(record) }
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    try await open().applyInbound(fetched.records, token: fetched.token, now: now)
    let reopened = try open()
    #expect(try await reopened.card(id: card.id)?.title == "Valid page content")
    #expect(try await reopened.syncSnapshot().token == fetched.token)
    try await reopened.transferSnapshot().validate()
    let artifacts = try await reopened.takeUnpresentedConflicts(now: now)
    #expect(artifacts.count == 1)
    let artifact = try #require(artifacts.first)
    #expect(artifact.inboundIssue == .undecodableRecord)
    #expect(artifact.losingPayload.count < 1024)
    #expect(try JSONDecoder().decode(InvalidInboundRecord.self, from: artifact.losingPayload).entityID == card.id.rawValue)
    #expect(artifact.losingPayload != bad["payload"] as? Data)
    #expect(!String(decoding: artifact.losingPayload, as: UTF8.self).contains("private undecodable bytes"))
    try await reopened.applyInbound(fetched.records, token: fetched.token, now: now)
    #expect(try await reopened.takeUnpresentedConflicts(now: now).isEmpty)
    #expect(try await reopened.pendingOutbox().allSatisfy { $0.entity != .conflict })
    #expect(try await reopened.conflicts().first?.expiresAt == now.addingTimeInterval(2_592_000))
}

@Test func decodedMalformedReminderKeepsRecoverableTextInsteadOfRawTransportBytes() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let card = try await sender.createCard(title: "Parent", now: now)
    var line = try await sender.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Recover this text"), now: now)
    line.reminder = Reminder(rule: .daily(localMinute: 1440, timeZoneIdentifier: "UTC"), isEnabled: true)
    var buffer = try EngineEventBuffer(checkpoint: nil)
    try buffer.receive([
        CloudRecordMapper.encode(ReplicatedRecord(payload: .card(card), generation: .initial)),
        CloudRecordMapper.encode(ReplicatedRecord(payload: .line(line), generation: .initial))
    ])
    let receiver = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let result = try buffer.fetchResult()
    try await receiver.applyInbound(result.records, token: result.token, now: now)
    #expect(try await receiver.lines(cardID: card.id).isEmpty)
    let artifact = try #require(await receiver.conflicts().first)
    #expect(artifact.inboundIssue == .reminder)
    #expect(try JSONDecoder().decode(CardLine.self, from: artifact.losingPayload).text == "Recover this text")
    try await receiver.transferSnapshot().validate()
}
