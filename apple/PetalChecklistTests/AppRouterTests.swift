import XCTest
import PetalCore
import PetalPersistence
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class AppRouterTests: XCTestCase {
    func testCaptureCommitFlushesDraftThenRefreshesVisibleEditor() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(inbox.id)
        router.editor?.editTitle("Local draft")
        router.editor?.editNewLine("Unsubmitted")
        _ = try await base.captureTodoLines(cardID: inbox.id, texts: ["Captured"], now: .now)
        await router.captureDidCommit(to: inbox.id)
        let saved = try await base.card(id: inbox.id)
        XCTAssertEqual(saved?.title, "Local draft")
        XCTAssertEqual(router.editor?.lines.map(\.text), ["Captured"])
        XCTAssertEqual(router.editor?.newLineDraft, "Unsubmitted")
        XCTAssertNil(router.editor?.unsavedTitle)
    }

    func testCaptureRefreshFailurePreservesUnsavedEditorDraftForRetry() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let active = try await base.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(inbox.id)
        router.editor?.editTitle("Keep draft")
        _ = try await base.captureTodoLines(cardID: inbox.id, texts: ["Captured"], now: .now)
        repository.failNextTitle = true
        await router.captureDidCommit(to: inbox.id)
        XCTAssertEqual(router.editor?.title, "Keep draft")
        XCTAssertEqual(router.editor?.unsavedTitle, "Keep draft")
        XCTAssertTrue(router.editor?.lines.isEmpty == true)
        XCTAssertNotNil(router.errorMessage)
        await router.retryError()
        XCTAssertEqual(router.editor?.lines.map(\.text), ["Captured"])
        XCTAssertNil(router.editor?.unsavedTitle)
    }
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

    func testCloseWaitsForFailedNewLineSubmissionAndKeepsDraftForRetry() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Card", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        let editor = try XCTUnwrap(router.editor)
        editor.editNewLine("Keep me")
        repository.addGate.pauseNext()
        repository.failNextAdd = true
        let submission = Task { try await editor.submitNewLine() }
        await repository.addGate.waitUntilEntered()
        let closing = Task { await router.prepareClose() }
        repository.addGate.resume()
        do {
            _ = try await submission.value
            XCTFail("The injected add failure should reach the submitter")
        } catch { }
        let closeAllowed = await closing.value
        XCTAssertFalse(closeAllowed)
        XCTAssertEqual(editor.newLineDraft, "Keep me")
        XCTAssertNotNil(editor.newLineError)
        XCTAssertFalse(router.isTransitioning)
        XCTAssertFalse(editor.isTransitionLocked)
        let beforeRetry = try await base.lines(cardID: card.id)
        XCTAssertTrue(beforeRetry.isEmpty)
        let retrySucceeded = try await editor.submitNewLine()
        XCTAssertTrue(retrySucceeded)
        let persisted = try await base.lines(cardID: card.id).map(\.text)
        XCTAssertEqual(persisted, ["Keep me"])
    }

    func testInboxReplacementRequiresChoiceWheneverCandidateExists() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let first = try await repository.createCard(title: "First", now: .now)
        let second = try await repository.createCard(title: "Second", now: .now)
        XCTAssertFalse(RootView.shouldPromptForInboxReplacement(candidates: []))
        XCTAssertTrue(RootView.shouldPromptForInboxReplacement(candidates: [first]))
        XCTAssertTrue(RootView.shouldPromptForInboxReplacement(candidates: [first, second]))
    }

    func testSuccessfulCloseRequestCanResetForReopenedScene() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let first = try await repository.createCard(title: "First", now: .now)
        let second = try await repository.createCard(title: "Second", now: .now)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(first.id)
        let allowed = await router.prepareClose()
        XCTAssertTrue(allowed)
        XCTAssertTrue(router.isTransitioning)
        router.closeRequestDidEnd()
        XCTAssertFalse(router.isTransitioning)
        XCTAssertFalse(router.editor?.isTransitionLocked ?? true)
        router.editor?.editTitle("Reopened")
        await router.select(second.id)
        let persistedTitle = try await repository.card(id: first.id)?.title
        XCTAssertEqual(persistedTitle, "Reopened")
        XCTAssertEqual(router.selectedCardID, second.id)
    }
}
