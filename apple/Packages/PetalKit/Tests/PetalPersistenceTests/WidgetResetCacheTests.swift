import Foundation
import Testing
import PetalCore
@testable import PetalPersistence

struct WidgetResetCacheTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func cacheEvictionAfterResetRebindsFreshReadsWithoutRevalidatingOldTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try open(root)
        let generation = UUID()
        try await repository.deleteAllData(resetGeneration: generation, now: now)
        try await repository.finishResetCleanup()
        let cardID = CardID(rawValue: generation)
        _ = try await repository.addLine(.init(cardID: cardID, kind: .todo, text: "Current dataset"), now: now)
        let directory = cacheDirectory(root)
        let cache = WidgetSnapshotCache(directory: directory)
        let oldToken = try await cache.beginRead(cardID: cardID)
        let old = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: cardID, size: .medium, now: now, calendar: calendar)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reset.generation"))
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { repository }
        #expect(await reader.snapshot(cardID: cardID, size: .medium, now: now, calendar: calendar).visibleLines.map(\.text) == ["Current dataset"])
        #expect(try await cache.store(old, token: oldToken, size: .medium, now: now, calendar: calendar) == false)
        let offline = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        #expect(await offline.snapshot(cardID: cardID, size: .medium, now: now, calendar: calendar).visibleLines.map(\.text) == ["Current dataset"])
    }

    @Test func tokenCreatedInsideResetCommitWindowCannotCacheOldRepositoryContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try open(root)
        let card = try await repository.createCard(title: "Precommit private title", now: now)
        _ = try await repository.addLine(.init(cardID: card.id, kind: .todo, text: "Precommit private line"), now: now)
        let directory = cacheDirectory(root)
        // Stage the production precommit hook while canonical storage still has
        // the old generation, then begin a new read against that exact window.
        try WidgetSnapshotCache.installResetFence(at: directory, generation: UUID())
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { repository }
        let result = await reader.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar)
        #expect(result.title.isEmpty)
        #expect(result.visibleLines.isEmpty)
        let offline = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        #expect(await offline.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar).visibleLines.isEmpty)
    }

    @Test func outstandingReaderCannotReturnItsPreResetContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try open(root)
        let card = try await repository.createCard(title: "Private old view", now: now)
        _ = try await repository.addLine(.init(cardID: card.id, kind: .todo, text: "Private old row"), now: now)
        let staleView = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await staleView.replaceUserData(repository.transferSnapshot(), now: now)
        let gate = SnapshotReadGate()
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: cacheDirectory(root))) {
            await gate.pause()
            return staleView
        }
        let pending = Task { await reader.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar) }
        await gate.waitUntilPaused()
        try await repository.deleteAllData(resetGeneration: UUID(), now: now.addingTimeInterval(1))
        try await repository.finishResetCleanup()
        await gate.resume()
        let result = await pending.value
        #expect(result.title.isEmpty)
        #expect(result.visibleLines.isEmpty)
    }

    @Test func unavailableResetFenceAbortsDeletionWithoutChangingCanonicalContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = cacheDirectory(root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let repository = try open(root)
        let card = try await repository.createCard(title: "Keep on failed reset", now: now)
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { repository }
        _ = await reader.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await repository.deleteAllData(resetGeneration: UUID(), now: now) }
        #expect(try await repository.card(id: card.id)?.title == "Keep on failed reset")
    }

    @Test(arguments: [false, true])
    func resetErasesPersistedContentAndRejectsOutstandingWrites(incoming: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try open(root)
        let card = try await repository.createCard(title: "Deleted private title", now: now)
        _ = try await repository.addLine(.init(cardID: card.id, kind: .todo, text: "Deleted private line"), now: now)
        let directory = cacheDirectory(root)
        let cache = WidgetSnapshotCache(directory: directory)
        let token = try await cache.beginRead(cardID: card.id)
        let old = try await WidgetSnapshotBuilder(repository: repository).snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar)
        try await cache.store(old, token: token, size: .medium, now: now, calendar: calendar)
        let generation = UUID()
        if incoming {
            let reset = ResetGeneration(id: generation, modifiedAt: now.addingTimeInterval(1), deviceID: "remote")
            try await repository.applyInbound([ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation,
                inboxCardID: CardID(rawValue: generation))), generation: reset)], token: nil, now: now.addingTimeInterval(1))
        } else { try await repository.deleteAllData(resetGeneration: generation, now: now.addingTimeInterval(1)) }
        try await repository.finishResetCleanup()
        // A read started before reset must not recreate its old content after cleanup or reopen.
        try await cache.store(old, token: token, size: .medium, now: now, calendar: calendar)
        let offline = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        let result = await offline.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar)
        #expect(result.title.isEmpty)
        #expect(result.visibleLines.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.isEmpty)
    }

    @Test func resetFenceHidesContentWhenErasureFailsAndCleanupRetriesAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = cacheDirectory(root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let repository = try open(root)
        let card = try await repository.createCard(title: "Private title", now: now)
        _ = try await repository.addLine(.init(cardID: card.id, kind: .todo, text: "Private line"), now: now)
        let reader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { repository }
        _ = await reader.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar)
        try await repository.deleteAllData(resetGeneration: UUID(), now: now.addingTimeInterval(1))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await repository.finishResetCleanup() }
        let offline = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
        #expect(await offline.snapshot(cardID: card.id, size: .medium, now: now, calendar: calendar).visibleLines.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await open(root).finishResetCleanup()
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.isEmpty)
        try await open(root).finishResetCleanup()
    }

    private func open(_ root: URL) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    private func cacheDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("Library/Caches/Petal/WidgetSnapshots", isDirectory: true)
    }
}

private actor SnapshotReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation {
            continuation = $0
            observer?.resume(); observer = nil
        }
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
