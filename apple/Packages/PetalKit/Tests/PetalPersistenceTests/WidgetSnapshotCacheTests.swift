import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalTestSupport

struct WidgetSnapshotCacheTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func recreatedReaderRecoversPersistedSameCardSizeAndDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 8, now: now)
        let firstReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { fixture.repository }
        let first = await firstReader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        let recreatedReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        let recovered = await recreatedReader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(recovered.cardState == .persistenceError)
        #expect(recovered.visibleLines == first.visibleLines)
        #expect(recovered.visibleLines.count == 5)
        #expect(recovered.hiddenCount == 3)
        #expect(recovered.cardID == fixture.fixtureCardID)
        let wrongCard = await recreatedReader.snapshot(cardID: CardID(rawValue: UUID()), size: .medium, now: now, calendar: calendar)
        let wrongSize = await recreatedReader.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
        let tomorrow = await recreatedReader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: first.nextRefresh, calendar: calendar)
        #expect(wrongCard.visibleLines.isEmpty)
        #expect(wrongSize.visibleLines.isEmpty)
        #expect(tomorrow.visibleLines.isEmpty)
    }

    @Test(arguments: [WidgetCardState.archived, .trashed, .unavailable])
    func confirmedInactiveCardInvalidatesContentAcrossSizes(state: WidgetCardState) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 8, now: now)
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { fixture.repository }
        for size in [WidgetDisplaySize.medium, .large] {
            _ = await reader.snapshot(cardID: fixture.fixtureCardID, size: size, now: now, calendar: calendar)
        }
        try await fixture.repository.moveCard(fixture.fixtureCardID, to: state == .archived ? .archived : .trashed,
            replacementInbox: nil, now: now)
        if state == .unavailable { try await fixture.repository.purgeExpiredTrash(now: now.addingTimeInterval(30 * 86400)) }
        let confirmation = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(confirmation.cardState == state)
        let recreatedReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        for size in [WidgetDisplaySize.medium, .large] {
            let failed = await recreatedReader.snapshot(cardID: fixture.fixtureCardID, size: size, now: now, calendar: calendar)
            #expect(failed.visibleLines.isEmpty)
        }
        let jsonFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(jsonFiles.isEmpty)
    }

    @Test(arguments: [false, true]) func corruptOrFutureSchemaCacheIsRemovedAndCanBeReplaced(futureSchema: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let value = try await WidgetSnapshotBuilder(repository: fixture.repository).snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        let cache = WidgetSnapshotCache(directory: directory)
        let token = try await cache.beginRead(cardID: value.cardID)
        try await cache.store(value, token: token, size: .medium, now: now, calendar: calendar)
        let url = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        if futureSchema {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["version"] = 999
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        } else { try Data("broken JSON".utf8).write(to: url) }
        #expect(try await cache.load(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await cache.store(value, token: token, size: .medium, now: now, calendar: calendar)
        #expect(try await cache.load(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar) == value)
    }

    @Test func cacheDoesNotCrossTimeZoneIdentityAndPrunesExpiredContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let value = try await WidgetSnapshotBuilder(repository: fixture.repository).snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        let cache = WidgetSnapshotCache(directory: directory)
        let token = try await cache.beginRead(cardID: value.cardID)
        try await cache.store(value, token: token, size: .medium, now: now, calendar: calendar)
        var otherZone = calendar
        otherZone.timeZone = TimeZone(identifier: "Europe/London")!
        #expect(try await cache.load(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: otherZone) == nil)
        #expect(try await cache.load(cardID: fixture.fixtureCardID, size: .medium, now: value.nextRefresh, calendar: calendar) == nil)
        let jsonFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(jsonFiles.isEmpty)
    }

    @Test func persistentCacheBoundsStoredContentToThirtyTwoSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotCache(directory: directory)
        for _ in 0..<34 {
            let snapshot = WidgetSnapshot(cardID: CardID(rawValue: UUID()), title: "Sample", visibleLines: [], hiddenCount: 0,
                cardState: .empty, nextRefresh: Date(timeIntervalSince1970: 1_800_057_600))
            let token = try await cache.beginRead(cardID: snapshot.cardID)
            try await cache.store(snapshot, token: token, size: .medium, now: now, calendar: calendar)
        }
        let jsonFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(jsonFiles.count == 32)
    }

    @Test func unavailableCacheCannotFallBackToProcessMemory() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let source = OnceRepository(repository: fixture.repository)
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: { throw RepositoryError.appGroupUnavailable })) { try await source.open() }
        let first = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(first.visibleLines.count == 1)
        let failed = await reader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(failed.cardState == .persistenceError)
        #expect(failed.visibleLines.isEmpty)
    }

    @Test(arguments: ["missing", "corrupt", "future"])
    func damagedGenerationMetadataRejectsOldReadAndFreshReadsRecover(damage: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1, now: now)
        let cache = WidgetSnapshotCache(directory: directory)
        let oldToken = try await cache.beginRead(cardID: fixture.fixtureCardID)
        let oldValue = try await WidgetSnapshotBuilder(repository: fixture.repository).snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        try await cache.store(oldValue, token: oldToken, size: .medium, now: now, calendar: calendar)
        let metadata = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "metadata" })
        switch damage {
        case "missing": try FileManager.default.removeItem(at: metadata)
        case "future":
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            json["version"] = 999
            try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        default: try Data("broken metadata".utf8).write(to: metadata)
        }
        let offline = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        #expect(await offline.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar).visibleLines.isEmpty)

        let line = try #require(await fixture.repository.lines(cardID: fixture.fixtureCardID).first)
        _ = try await fixture.repository.updateLine(.init(id: line.id, kind: .todo, text: "Fresh", reminder: nil), now: now)
        let freshReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { fixture.repository }
        _ = await freshReader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        // A token acquired before metadata loss/corruption must never regain validity.
        try? await cache.store(oldValue, token: oldToken, size: .medium, now: now, calendar: calendar)
        let recovered = await offline.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
        #expect(recovered.visibleLines.map(\.text) == ["Fresh"])
    }

    @Test func generationEvictionBoundsMetadataWithoutRevalidatingOldTokens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotCache(directory: directory)
        let snapshot = WidgetSnapshot(cardID: CardID(rawValue: UUID()), title: "Old read", visibleLines: [], hiddenCount: 0,
            cardState: .empty, nextRefresh: Date(timeIntervalSince1970: 1_800_057_600))
        let oldToken = try await cache.beginRead(cardID: snapshot.cardID)
        for _ in 0..<128 { _ = try await cache.beginRead(cardID: CardID(rawValue: UUID())) }
        try await cache.store(snapshot, token: oldToken, size: .medium, now: now, calendar: calendar)
        #expect(try await cache.load(cardID: snapshot.cardID, size: .medium, now: now, calendar: calendar) == nil)
        let metadata = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "metadata" })
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect((json["generations"] as? [Any])?.count == 128)

        let newToken = try await cache.beginRead(cardID: snapshot.cardID)
        try await cache.store(snapshot, token: newToken, size: .medium, now: now, calendar: calendar)
        #expect(try await cache.load(cardID: snapshot.cardID, size: .medium, now: now, calendar: calendar) == snapshot)
    }
}

private actor OnceRepository {
    private var repository: (any PetalRepository)?
    init(repository: any PetalRepository) { self.repository = repository }
    func open() throws -> any PetalRepository {
        guard let repository else { throw RepositoryError.appGroupUnavailable }
        self.repository = nil
        return repository
    }
}
