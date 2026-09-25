import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class DeepLinkHandlerTests: XCTestCase {
    func testCardLinkPublishesMatchingLibraryFromSettingsAndTrashUsingFinalStatus() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Target", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        let handler = DeepLinkHandler(router: router) { _ in XCTFail("Unexpected capture") }
        for source in [LibraryScope.settings, .trash] {
            try await base.moveCard(card.id, to: .active, replacementInbox: nil, now: .now)
            await router.show(source)
            await handler.handle(PetalDeepLink.card(card.id).url)
            XCTAssertEqual(router.scope, .allCards)
            XCTAssertEqual(router.library.scope, .allCards)
            XCTAssertTrue(router.library.cards.contains { $0.id == card.id })
        }
        await router.show(.settings)
        repository.linesGate.pauseNext()
        let routing = Task { await handler.handle(PetalDeepLink.card(card.id).url) }
        await repository.linesGate.waitUntilEntered()
        try await base.moveCard(card.id, to: .archived, replacementInbox: nil, now: .now)
        repository.linesGate.resume()
        await routing.value
        XCTAssertEqual(router.scope, .archive)
        XCTAssertEqual(router.library.scope, .archive)
        XCTAssertEqual(router.library.cards.map(\.id), [card.id])
        XCTAssertEqual(router.editor?.status, .archived)
    }

    func testMalformedArrivalSupersedesSuspendedValidRoute() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Target", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.show(.settings)
        let handler = DeepLinkHandler(router: router) { _ in XCTFail("Unexpected capture") }
        repository.cardGate.pauseNext()
        let valid = Task { await handler.handle(PetalDeepLink.card(card.id).url) }
        await repository.cardGate.waitUntilEntered()
        var rejectionStarted = false
        let rejected = Task {
            rejectionStarted = true
            await handler.handle(URL(string: "petal://card/invalid")!)
        }
        while !rejectionStarted { await Task.yield() }
        repository.cardGate.resume()
        await valid.value
        await rejected.value
        XCTAssertNil(router.selectedCardID)
        XCTAssertEqual(router.scope, .settings)
        XCTAssertEqual(router.library.scope, .settings)
        XCTAssertEqual(router.errorMessage, DeepLinkError.invalidLink.errorDescription)
    }

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
