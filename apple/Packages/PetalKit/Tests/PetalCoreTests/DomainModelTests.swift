import Foundation
import Testing
@testable import PetalCore

@Test func cardAndLineRetainIdentityAndSyncMetadataAcrossJSON() throws {
    let cardID = CardID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let lineID = LineID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let card = Card(
        id: cardID, title: "清单", status: .active, themeID: .sakura,
        isInbox: true, createdAt: instant, modifiedAt: instant,
        archivedAt: nil, deletedAt: nil, revision: 4, deviceID: "mac-1"
    )
    let line = CardLine(
        id: lineID, cardID: cardID, kind: .todo, text: "牛奶", sortIndex: 7,
        isCompleted: true, completedAt: instant, lastDailyCompletionKey: "2027-01-15",
        dailyStreak: 3,
        reminder: Reminder(rule: .daily(localMinute: 540, timeZoneIdentifier: "Asia/Shanghai"), isEnabled: true),
        createdAt: instant, modifiedAt: instant, deletedAt: nil, revision: 2, deviceID: "mac-1"
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(try decoder.decode(Card.self, from: encoder.encode(card)) == card)
    #expect(try decoder.decode(CardLine.self, from: encoder.encode(line)) == line)
}

@Test func conflictArtifactRetainsLosingPayloadAcrossJSON() throws {
    let cardID = CardID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let artifact = ConflictArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        cardID: cardID, lineID: nil,
        losingPayload: Data([0, 1, 255]),
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_802_592_000),
        hasBeenPresented: false
    )

    let encoded = try JSONEncoder().encode(artifact)
    #expect(try JSONDecoder().decode(ConflictArtifact.self, from: encoded) == artifact)
}
