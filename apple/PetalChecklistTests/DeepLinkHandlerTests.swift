import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class DeepLinkHandlerTests: XCTestCase {
    func testMalformedLinksNeverSelectOrCapture() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        var captures: [CardID] = []
        let handler = DeepLinkHandler(router: router) { captures.append($0) }
        let id = "20F46FAB-23E3-4914-B0E0-5BE0CB39045F"
        for raw in ["petal://card/nope", "petal://quick-add", "https://card/\(id)",
                    "petal://card/\(id)/extra", "petal://card/\(id)?x=1", "petal://card/\(id)#x",
                    "petal://user@card/\(id)", "petal://card:1/\(id)", "petal://unknown/\(id)"] {
            await handler.handle(URL(string: raw)!)
            XCTAssertNil(router.selectedCardID)
            XCTAssertNotNil(router.errorMessage)
        }
        XCTAssertTrue(captures.isEmpty)
    }

    func testCardStatusMatrixNeverFallsBack() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "private", now: .now)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        var captures: [CardID] = []
        let handler = DeepLinkHandler(router: router) { captures.append($0) }
        for status in [CardStatus.active, .archived, .trashed] {
            try await repository.moveCard(card.id, to: status, replacementInbox: nil, now: .now)
            await router.show(.settings)
            await handler.handle(PetalDeepLink.card(card.id).url)
            XCTAssertEqual(router.selectedCardID, status == .trashed ? nil : card.id)
            if status != .trashed { XCTAssertNotEqual(router.scope, .settings) }
            await handler.handle(PetalDeepLink.quickAdd(card.id).url)
            XCTAssertEqual(captures.count, 1)
            if status != .active { XCTAssertNotNil(router.errorMessage) }
        }
        await router.show(.settings)
        await handler.handle(PetalDeepLink.card(CardID(rawValue: UUID())).url)
        XCTAssertNil(router.selectedCardID)
        XCTAssertNotNil(router.errorMessage)
    }

    func testRoutingFlushesDraftAndFailureKeepsSelectionForRetry() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let a = try await base.createCard(title: "A", now: .now)
        let b = try await base.createCard(title: "B", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        var captures: [CardID] = []
        let handler = DeepLinkHandler(router: router) { captures.append($0) }
        await router.select(a.id)
        router.editor?.editTitle("Draft")
        router.editor?.editNewLine("Unsubmitted")
        repository.failNextTitle = true
        await handler.handle(PetalDeepLink.card(b.id).url)
        XCTAssertEqual(router.selectedCardID, a.id)
        XCTAssertEqual(router.editor?.unsavedTitle, "Draft")
        XCTAssertNotNil(router.errorMessage)
        await router.retryError()
        XCTAssertEqual(router.selectedCardID, b.id)
        let saved = try await base.card(id: a.id)
        XCTAssertEqual(saved?.title, "Draft")
        await handler.handle(PetalDeepLink.card(a.id).url)
        XCTAssertEqual(router.editor?.newLineDraft, "Unsubmitted")
        router.editor?.editTitle("Before capture")
        await handler.handle(PetalDeepLink.quickAdd(b.id).url)
        let updated = try await base.card(id: a.id)
        XCTAssertEqual(updated?.title, "Before capture")
        XCTAssertEqual(captures, [b.id])
        XCTAssertEqual(router.selectedCardID, a.id)
    }
}
