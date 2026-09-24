import XCTest
import SwiftUI
import WidgetKit
import PetalCore
import PetalPersistence
import PetalTestSupport

@MainActor
final class WidgetPresentationTests: XCTestCase {
    func testGalleryIgnoresConfiguredCardAndDoesNotOpenStore() async {
        let provider = ChecklistTimelineProvider(reader: WidgetSnapshotReader { throw RepositoryError.injectedFailure })
        let intent = ChecklistWidgetConfigurationIntent()
        intent.card = CardEntity(id: UUID(), title: "PRIVATE TITLE")
        let entry = await provider.entry(configuration: intent, family: .systemMedium, isPreview: true,
            now: Date(timeIntervalSince1970: 1_800_000_000), calendar: Calendar(identifier: .gregorian))
        XCTAssertNotEqual(entry.snapshot.cardID.rawValue, intent.card?.id)
        XCTAssertEqual(entry.snapshot.title, "Petal")
        XCTAssertEqual(entry.snapshot.visibleLines.count, 3)
        XCTAssertEqual(entry.snapshot.cardState, .normal)
    }

    func testProviderMapsFamilyAndKeepsSelectedCardOnFailure() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 12)
        let provider = ChecklistTimelineProvider(reader: WidgetSnapshotReader { fixture.repository })
        let intent = ChecklistWidgetConfigurationIntent()
        intent.card = CardEntity(id: fixture.fixtureCardID.rawValue, title: "Stale title")
        for (family, count) in [(WidgetFamily.systemMedium, 5), (.systemLarge, 10)] {
            let entry = await provider.entry(configuration: intent, family: family, isPreview: false,
                now: .now, calendar: .current)
            XCTAssertEqual(entry.snapshot.visibleLines.count, count)
            XCTAssertEqual(entry.snapshot.cardID, fixture.fixtureCardID)
            XCTAssertEqual(entry.snapshot.title, "Fixture")
        }
        let failed = ChecklistTimelineProvider(reader: WidgetSnapshotReader { throw RepositoryError.appGroupUnavailable })
        let entry = await failed.entry(configuration: intent, family: .systemMedium, isPreview: false,
            now: .now, calendar: .current)
        XCTAssertEqual(entry.snapshot.cardState, .persistenceError)
        XCTAssertEqual(entry.snapshot.cardID, fixture.fixtureCardID)
    }

    func testUnconfiguredWidgetRequiresSelectionWithoutOpeningStore() async {
        let provider = ChecklistTimelineProvider(reader: WidgetSnapshotReader { throw RepositoryError.injectedFailure })
        let entry = await provider.entry(configuration: ChecklistWidgetConfigurationIntent(), family: .systemMedium,
            isPreview: false, now: .now, calendar: .current)
        XCTAssertEqual(entry.snapshot.cardState, .unavailable)
    }

    func testErrorTimelineRetriesWithinFifteenMinutesAndNeverAfterMidnight() async {
        let provider = ChecklistTimelineProvider(reader: WidgetSnapshotReader { throw RepositoryError.appGroupUnavailable })
        let intent = ChecklistWidgetConfigurationIntent()
        intent.card = CardEntity(id: UUID(), title: "Configured")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (now, expected) in [(1_800_000_000.0, 1_800_000_900.0), (1_800_057_500.0, 1_800_057_600.0)] {
            let entry = await provider.entry(configuration: intent, family: .systemMedium, isPreview: false,
                now: Date(timeIntervalSince1970: now), calendar: calendar)
            let timeline = provider.timeline(for: entry)
            XCTAssertEqual(timeline.policy, .after(Date(timeIntervalSince1970: expected)))
            XCTAssertEqual(entry.snapshot.nextRefresh, Date(timeIntervalSince1970: 1_800_057_600))
        }
    }

    func testSuccessfulTimelineRetainsMidnightRefresh() async throws {
        let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 1)
        let provider = ChecklistTimelineProvider(reader: WidgetSnapshotReader { fixture.repository })
        let intent = ChecklistWidgetConfigurationIntent()
        intent.card = CardEntity(id: fixture.fixtureCardID.rawValue, title: "Configured")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let entry = await provider.entry(configuration: intent, family: .systemMedium, isPreview: false,
            now: Date(timeIntervalSince1970: 1_800_000_000), calendar: calendar)
        XCTAssertEqual(provider.timeline(for: entry).policy, .after(Date(timeIntervalSince1970: 1_800_057_600)))
    }

    func testDelayedActiveReadCannotRepopulateInvalidatedCacheAfterRestart() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for state in [WidgetCardState.archived, .trashed, .unavailable] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try await InMemoryPetalRepository.cardWithTodos(count: 8, now: now)
            let gated = ControlledRepository(base: fixture.repository)
            let delayedReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { gated }
            let confirmingReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { fixture.repository }
            _ = await confirmingReader.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)

            gated.linesGate.pauseNext()
            defer { gated.linesGate.resume() }
            let oldRead = Task { await delayedReader.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar) }
            await gated.linesGate.waitUntilEntered() // A has already read the active card and its lines.
            try await fixture.repository.moveCard(fixture.fixtureCardID, to: state == .archived ? .archived : .trashed,
                replacementInbox: nil, now: now)
            if state == .unavailable { try await fixture.repository.purgeExpiredTrash(now: now.addingTimeInterval(30 * 86400)) }
            let confirmation = await confirmingReader.snapshot(cardID: fixture.fixtureCardID, size: .medium, now: now, calendar: calendar)
            XCTAssertEqual(confirmation.cardState, state)
            gated.linesGate.resume() // A finishes only after B has confirmed and invalidated.
            _ = await oldRead.value

            let restarted = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { throw RepositoryError.appGroupUnavailable }
            let recovered = await restarted.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
            XCTAssertEqual(recovered.cardState, .persistenceError)
            XCTAssertTrue(recovered.visibleLines.isEmpty, "Delayed active read repopulated cache after \(state)")

            if state != .unavailable {
                try await fixture.repository.moveCard(fixture.fixtureCardID, to: .active, replacementInbox: nil, now: now)
                let restoredReader = WidgetSnapshotReader(cache: WidgetSnapshotCache(directory: directory)) { fixture.repository }
                _ = await restoredReader.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
                let restored = await restarted.snapshot(cardID: fixture.fixtureCardID, size: .large, now: now, calendar: calendar)
                XCTAssertEqual(restored.visibleLines.count, 8, "A fresh read after restore must be cacheable")
            }
        }
    }

    func testPreviewMatrixRendersAtWidgetSizes() throws {
        // These attachments are visual-review evidence, not pixel-golden assertions.
        for scenario in ChecklistWidgetPreviews.scenarios {
            let renderer = ImageRenderer(content: ChecklistWidgetView(entry: scenario.entry)
                .environment(\.colorScheme, scenario.dark ? .dark : .light)
                .environment(\.widgetRenderingMode, scenario.vibrant ? .vibrant : .fullColor)
                .environment(\.dynamicTypeSize, scenario.largeText ? .accessibility3 : .large)
                .padding(16).frame(width: 344, height: scenario.large ? 360 : 170)
                .background(scenario.dark ? Color.black : Color.white))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = scenario.name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let data = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("petal-task6-\(scenario.name).png"))
            }
        }
    }
}
