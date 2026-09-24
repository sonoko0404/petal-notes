import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class AppRouterTests: XCTestCase {
    func testOverlappingSelectionPublishesLatestAndBlocksEditingDuringTransition() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first)
        let b = try await base.createCard(title: "B", now: .now)
        let c = try await base.createCard(title: "C", now: .now)
        let repository = ControlledRepository(base: base)
        let library = CardLibraryModel(repository: repository)
        let router = AppRouter(repository: repository, library: library)
        await router.select(inbox.id)
        repository.cardGate.pauseNext()
        let first = Task { await router.select(b.id) }
        await repository.cardGate.waitUntilEntered()
        XCTAssertTrue(router.isTransitioning)
        let before = router.editor?.title
        router.editor?.editTitle("During transition")
        XCTAssertEqual(router.editor?.title, before)
        let second = Task { await router.select(c.id) }
        first.cancel()
        repository.cardGate.resume()
        await first.value
        await second.value
        XCTAssertEqual(router.selectedCardID, c.id)
        XCTAssertEqual(router.editor?.cardID, c.id)
        XCTAssertFalse(router.isTransitioning)
    }

    func testNewLineDraftsRemainWithTheirOwnCardsAcrossNavigation() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let a = try await repository.createCard(title: "A", now: .now)
        let b = try await repository.createCard(title: "B", now: .now)
        let library = CardLibraryModel(repository: repository)
        let router = AppRouter(repository: repository, library: library)
        await router.select(a.id)
        router.editor?.editNewLine("A draft")
        await router.select(b.id)
        XCTAssertEqual(router.editor?.newLineDraft, "")
        router.editor?.editNewLine("B draft")
        await router.select(a.id)
        XCTAssertEqual(router.editor?.newLineDraft, "A draft")
        await router.select(b.id)
        XCTAssertEqual(router.editor?.newLineDraft, "B draft")
    }

    func testFailedSelectionKeepsCurrentEditorAndRetryCompletesNavigation() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let a = try await base.createCard(title: "A", now: .now)
        let b = try await base.createCard(title: "B", now: .now)
        let repository = ControlledRepository(base: base)
        let library = CardLibraryModel(repository: repository)
        let router = AppRouter(repository: repository, library: library)
        await router.select(a.id)
        repository.failNextCard = true
        await router.select(b.id)
        XCTAssertEqual(router.selectedCardID, a.id)
        XCTAssertNotNil(router.errorMessage)
        await router.retryError()
        XCTAssertEqual(router.selectedCardID, b.id)
        XCTAssertNil(router.errorMessage)
    }

    func testCreateRetryAfterEditorLoadFailureSelectsCommittedCardWithoutDuplicate() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let repository = ControlledRepository(base: base)
        let library = CardLibraryModel(repository: repository)
        let router = AppRouter(repository: repository, library: library)
        repository.failNextCard = true
        await router.createCard()
        XCTAssertNotNil(router.errorMessage)
        let created = try await base.cards(scope: .all).filter { $0.title == String(localized: "Untitled Card") }
        XCTAssertEqual(created.count, 1)
        await router.retryError()
        XCTAssertEqual(router.selectedCardID, created.first?.id)
        let after = try await base.cards(scope: .all).filter { $0.title == String(localized: "Untitled Card") }
        XCTAssertEqual(after.count, 1)
    }

    func testCloseKeepsEditorDisabledWhileQueuedNavigationFinishes() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let a = try await base.createCard(title: "A", now: .now)
        let b = try await base.createCard(title: "B", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(a.id)
        repository.cardGate.pauseNext()
        let navigation = Task { await router.select(b.id) }
        await repository.cardGate.waitUntilEntered()
        let closing = Task { await router.prepareClose() }
        repository.cardGate.resume()
        await navigation.value
        let allowed = await closing.value
        XCTAssertTrue(allowed)
        XCTAssertTrue(router.isTransitioning)
        XCTAssertEqual(router.selectedCardID, a.id)
    }
}
