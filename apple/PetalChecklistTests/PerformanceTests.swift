import XCTest
import PetalCore
import PetalPersistence
import PetalActions
@testable import PetalChecklist

/// Production disk factory + transactions; fixture work/warmup excluded from measured intervals.
@MainActor final class PerformanceTests: XCTestCase {
    func testUITimingStoreReopensRealDiskData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetalTimingStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SwiftDataPetalRepository(container: try AppEnvironment.testStore(directory: root))
        let card = try await first.createCard(title: "Durable fixture", now: .now)
        let second = SwiftDataPetalRepository(container: try AppEnvironment.testStore(directory: root))
        let reopened = try await second.cards(scope: .all)
        XCTAssertTrue(reopened.contains { $0.id == card.id })
    }
    func testFiveThousandRowsOnProductionDiskPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetalPerf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, snapshot) = try await PerformanceFixture.make(root: root)
        XCTAssertEqual(snapshot.cards.count, 500)
        XCTAssertEqual(snapshot.lines.count, 5000)
        _ = try await repository.search("warmup")
        let clock = ContinuousClock()
        let start = clock.now
        let matches = try await repository.search("needle")
        let search = start.duration(to: clock.now)
        XCTAssertEqual(matches.count, 500)
        print("PETAL_PERF search_ms=\(milliseconds(search))")

        let id = try XCTUnwrap(snapshot.lines.first?.id)
        let cardID = try XCTUnwrap(snapshot.lines.first?.cardID)
        // Uses the shipped SyncingWidgetTodoAction, native scheduler and disabled sync.
        // Includes store reopen, intent FIFO, commit, reconciliation and reload (a conservative upper bound on local save).
        let action = SyncingWidgetTodoAction(openRepository: { try Self.openStore(root) },
            containerIdentifier: "iCloud.com.petalchecklist", reloadWidgets: {})
        // Warm up the complete native path with two real transactions, outside the interval.
        for completed in [true, false] {
            let warmup = await ToggleTodoIntent(lineID: id, completed: completed).perform(
                action: action, reloader: SystemWidgetReloader(), clock: { .now })
            XCTAssertEqual(warmup, .success)
        }
        let intent = ToggleTodoIntent(lineID: id, completed: true)
        let intentStart = clock.now
        let outcome = await intent.perform(action: action, reloader: SystemWidgetReloader(), clock: { .now })
        let elapsed = intentStart.duration(to: clock.now)
        XCTAssertEqual(outcome, .success)
        let reopened = try open(root)
        let persisted = try await reopened.lines(cardID: cardID)
        XCTAssertTrue(try XCTUnwrap(persisted.first(where: { $0.id == id })).isCompleted)
        print("PETAL_PERF widget_save_ms=\(milliseconds(elapsed))")
    }
    private func open(_ root: URL) throws -> SwiftDataPetalRepository { try Self.openStore(root) }
    nonisolated private static func openStore(_ root: URL) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "performance.fixture", containerURL: { _ in root }))
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
