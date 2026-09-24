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
