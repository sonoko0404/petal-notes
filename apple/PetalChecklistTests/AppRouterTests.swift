import XCTest
import PetalCore
import PetalPersistence
import PetalSync
import AppKit
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class AppRouterTests: XCTestCase {
    func testSyncRefreshReloadsCommittedContentAndClearsDeletedSelection() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let card = try await repository.createCard(title: "Old", now: .now)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        _ = try await repository.updateCardTitle(card.id, title: "Remote", now: .now)
        await router.syncDidCommit()
        XCTAssertEqual(router.editor?.title, "Remote")
        try await repository.deleteAllData(resetGeneration: UUID(), now: .now)
        await router.syncDidCommit()
        XCTAssertNil(router.selectedCardID)
        XCTAssertNil(router.editor)
        XCTAssertEqual(router.library.cards.count, 1)
    }
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

    func testCaptureRefreshDoesNotSupersedePendingCardSelection() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let a = try await base.createCard(title: "A", now: .now)
        let b = try await base.createCard(title: "B", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(a.id)
        _ = try await base.captureTodoLines(cardID: a.id, texts: ["Captured"], now: .now)

        repository.cardGate.pauseNext()
        let selection = Task { await router.select(b.id) }
        await repository.cardGate.waitUntilEntered()
        let refresh = Task { await router.captureDidCommit(to: a.id) }
        await Task.yield()
        repository.cardGate.resume()
        await selection.value
        await refresh.value

        XCTAssertEqual(router.selectedCardID, b.id)
        XCTAssertEqual(router.editor?.cardID, b.id)
        XCTAssertNil(router.errorMessage)
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
        let created = try await base.cards(scope: .all).filter { !$0.isInbox }
        XCTAssertEqual(created.count, 1)
        await router.retryError()
        XCTAssertEqual(router.selectedCardID, created.first?.id)
        let after = try await base.cards(scope: .all).filter { !$0.isInbox }
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

    func testApplicationTerminationDefersUntilInflightEditorSaveSucceeds() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        repository.titleGate.pauseNext()
        router.editor?.editTitle("Saved before quit")
        let coordinator = ApplicationTerminationCoordinator()
        coordinator.prepare = { await router.prepareClose() }
        var reply: Bool?

        XCTAssertEqual(coordinator.request { reply = $0 }, .terminateLater)
        await repository.titleGate.waitUntilEntered()
        XCTAssertNil(reply)
        repository.titleGate.resume()
        while reply == nil { await Task.yield() }

        XCTAssertEqual(reply, true)
        let savedCard = try await base.card(id: card.id)
        XCTAssertEqual(savedCard?.title, "Saved before quit")
    }

    func testApplicationTerminationCancelsWhenEditorSaveFailsAndKeepsDraft() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        repository.failNextTitle = true
        router.editor?.editTitle("Keep this draft")
        let coordinator = ApplicationTerminationCoordinator()
        coordinator.prepare = { await router.prepareClose() }
        var reply: Bool?

        XCTAssertEqual(coordinator.request { reply = $0 }, .terminateLater)
        while reply == nil { await Task.yield() }

        XCTAssertEqual(reply, false)
        XCTAssertEqual(router.editor?.unsavedTitle, "Keep this draft")
        XCTAssertFalse(router.isTransitioning)
        let unchangedCard = try await base.card(id: card.id)
        XCTAssertEqual(unchangedCard?.title, "Before")
    }

    func testWindowCloseAndApplicationTerminationShareOneSaveDrain() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        repository.titleGate.pauseNext()
        router.editor?.editTitle("One drain")
        let windowClose = Task { await router.prepareClose() }
        await repository.titleGate.waitUntilEntered()
        let applicationQuit = Task { await router.prepareClose() }
        repository.titleGate.resume()

        let windowAllowed = await windowClose.value
        let quitAllowed = await applicationQuit.value
        XCTAssertTrue(windowAllowed)
        XCTAssertTrue(quitAllowed)
        let savedCard = try await base.card(id: card.id)
        XCTAssertEqual(savedCard?.title, "One drain")
    }

    func testSkippedForeignCommitReplaysAfterCloseWithSyncDisabled() async throws {
        try await assertSkippedForeignCommitReplaysAfterClose { repository in
            try await repository.setSyncEnabled(false)
        }
    }

    func testSkippedForeignCommitReplaysAfterCloseWithSyncFailed() async throws {
        try await assertSkippedForeignCommitReplaysAfterClose { repository in
            try await repository.recordSyncState(.failed(.quotaExceeded), retryAt: nil)
        }
    }

    private func assertSkippedForeignCommitReplaysAfterClose(
        configureSync: (SwiftDataPetalRepository) async throws -> Void
    ) async throws {
        let base = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await base.bootstrap(now: .now)
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        try await configureSync(base)
        let closeAllowed = await router.prepareClose()
        XCTAssertTrue(closeAllowed)
        _ = try await base.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Foreign"), now: .now)

        await router.syncDidCommit()
        XCTAssertTrue(router.editor?.lines.isEmpty == true)
        repository.linesGate.pauseNext()
        router.closeRequestDidEnd()
        router.editor?.editTitle("Draft after reopen")
        await repository.linesGate.waitUntilEntered()
        repository.linesGate.resume()
        await router.syncDidCommit()

        XCTAssertEqual(router.editor?.lines.map(\.text), ["Foreign"])
        XCTAssertNil(router.editor?.unsavedTitle)
        let savedTitle = try await base.card(id: card.id)?.title
        XCTAssertEqual(savedTitle, "Draft after reopen")
    }

    func testSkippedForeignCommitDoesNotRetryFailedCloseOrOverwriteDraft() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        router.editor?.editTitle("Keep draft")
        repository.titleGate.pauseNext()
        repository.failNextTitle = true
        let closing = Task { await router.prepareClose() }
        await repository.titleGate.waitUntilEntered()
        _ = try await base.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Foreign"), now: .now)
        await router.syncDidCommit()
        repository.titleGate.resume()

        let closeAllowed = await closing.value
        XCTAssertFalse(closeAllowed)
        XCTAssertEqual(router.editor?.unsavedTitle, "Keep draft")
        XCTAssertTrue(router.editor?.lines.isEmpty == true)
        let savedTitle = try await base.card(id: card.id)?.title
        XCTAssertEqual(savedTitle, "Before")
    }

    func testForeignCommitQueuedBeforeCloseReplaysWhenItsTransitionWasSkipped() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let first = try await base.createCard(title: "First", now: .now)
        let second = try await base.createCard(title: "Second", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(first.id)
        _ = try await base.addLine(NewLineDraft(cardID: first.id, kind: .todo, text: "Foreign"), now: .now)
        repository.cardGate.pauseNext()
        let navigation = Task { await router.select(second.id) }
        await repository.cardGate.waitUntilEntered()
        let commit = Task { await router.syncDidCommit() }
        await Task.yield()
        let closing = Task { await router.prepareClose() }
        repository.cardGate.resume()
        await navigation.value
        let closeAllowed = await closing.value
        XCTAssertTrue(closeAllowed)
        XCTAssertTrue(router.editor?.lines.isEmpty == true)

        repository.linesGate.pauseNext()
        router.closeRequestDidEnd()
        await repository.linesGate.waitUntilEntered()
        repository.linesGate.resume()
        await commit.value
        await router.syncDidCommit()

        XCTAssertEqual(router.selectedCardID, first.id)
        XCTAssertEqual(router.editor?.lines.map(\.text), ["Foreign"])
    }

    func testRepositoryCommitRefreshesWidgetChangeAfterSavingDraftAndInvalidatesLocally() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        router.editor?.editTitle("Local draft")
        _ = try await base.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "From Widget"), now: .now)
        var reminderInvalidations = 0
        var widgetReloads = 0
        let runtime = AppRepositoryCommitRuntime(router: router,
            reconcileReminders: { reminderInvalidations += 1 },
            reloadWidgets: { widgetReloads += 1 })

        await runtime.handleCommit()

        XCTAssertEqual(router.editor?.title, "Local draft")
        XCTAssertEqual(router.editor?.lines.map(\.text), ["From Widget"])
        XCTAssertNil(router.editor?.unsavedTitle)
        XCTAssertEqual(reminderInvalidations, 1)
        XCTAssertEqual(widgetReloads, 1)
    }

    func testRepositoryCommitFailureKeepsDraftWhileStillInvalidatingWidgetsAndReminders() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Before", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        router.editor?.editTitle("Keep draft")
        repository.failNextTitle = true
        var reminderInvalidations = 0
        var widgetReloads = 0
        let runtime = AppRepositoryCommitRuntime(router: router,
            reconcileReminders: { reminderInvalidations += 1 },
            reloadWidgets: { widgetReloads += 1 })

        await runtime.handleCommit()

        XCTAssertEqual(router.editor?.unsavedTitle, "Keep draft")
        XCTAssertEqual(router.editor?.title, "Keep draft")
        XCTAssertNotNil(router.errorMessage)
        XCTAssertEqual(reminderInvalidations, 1)
        XCTAssertEqual(widgetReloads, 1)
    }

    func testRepositoryCommitDuringHeldReconcileTriggersFreshStoreRead() async throws {
        let base = try await InMemoryPetalRepository.bootstrapped()
        let card = try await base.createCard(title: "Commit queue", now: .now)
        let repository = ControlledRepository(base: base)
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        await router.select(card.id)
        _ = try await base.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "First"), now: .now)
        let reconcileGate = RepositoryGate()
        reconcileGate.pauseNext()
        let runtime = AppRepositoryCommitRuntime(router: router,
            reconcileReminders: { await reconcileGate.enter() },
            reloadWidgets: {})

        let firstCommit = Task { await runtime.handleCommit() }
        await reconcileGate.waitUntilEntered()
        _ = try await base.addLine(NewLineDraft(cardID: card.id, kind: .todo, text: "Second"), now: .now)
        let secondCommit = Task { await runtime.handleCommit() }
        await Task.yield()
        reconcileGate.resume()
        await firstCommit.value
        await secondCommit.value

        XCTAssertEqual(router.editor?.lines.map(\.text), ["First", "Second"])
    }

    func testCrossProcessCommitIgnoresCurrentProcessAndHandlesForeignProcess() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let router = AppRouter(repository: repository, library: CardLibraryModel(repository: repository))
        var invalidations = 0
        let runtime = AppRepositoryCommitRuntime(router: router,
            reconcileReminders: { invalidations += 1 },
            reloadWidgets: {})

        await runtime.handleCrossProcessCommit(
            senderProcessIdentifier: String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(invalidations, 0)

        await runtime.handleCrossProcessCommit(senderProcessIdentifier: "foreign-process")
        XCTAssertEqual(invalidations, 1)
    }
}

private actor SettingsCloudTransport: CloudTransport {
    var calls = 0
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        calls += 1; throw CloudTransportError.quotaExceeded
    }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult { CloudSendResult(acceptedIDs: []) }
}

@MainActor final class SyncSettingsModelTests: XCTestCase {
    func testCloudPushPostsValueOnlyLifecycleTrigger() async {
        let received = expectation(description: "Push lifecycle trigger")
        let token = NotificationCenter.default.addObserver(forName: .petalCloudPushReceived, object: nil, queue: nil) { notification in
            XCTAssertNil(notification.userInfo)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let delegate = PetalAppDelegate()
        delegate.application(NSApplication.shared, didReceiveRemoteNotification: ["private": "must not propagate"])
        await fulfillment(of: [received], timeout: 1)
    }
    func testSettingsObservesSyncStartedByOtherLifecycleTrigger() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let sync = CloudSyncCoordinator(repository: repository, transport: SettingsCloudTransport())
        let model = SyncSettingsModel(repository: repository, coordinator: sync)
        await model.startObserving()
        await sync.sync(reason: .push)
        XCTAssertEqual(model.state, .failed(.quotaExceeded))
    }
    func testSettingsKeepsPersistentConflictRecoveryAfterNoticeDismissalAndRelaunch() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let card = try await repository.createCard(title: "Keep", now: .now)
        let conflict = try await repository.captureConflict(cardID: card.id, lineID: nil,
            losingPayload: try JSONEncoder().encode(card), now: .now)
        let transport = SettingsCloudTransport()
        let sync = CloudSyncCoordinator(repository: repository, transport: transport)
        let model = SyncSettingsModel(repository: repository, coordinator: sync)
        await model.load()
        XCTAssertEqual(model.conflicts.count, 1)
        XCTAssertEqual(model.unpresentedConflictCount, 1)
        model.dismissConflictNotice()
        XCTAssertEqual(model.conflicts.count, 1)
        XCTAssertEqual(model.unpresentedConflictCount, 0)
        await model.setEnabled(false)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.enabled)
        await model.setEnabled(true)
        XCTAssertEqual(model.state, .failed(.quotaExceeded))
        model.requestReset()
        XCTAssertTrue(model.isResetRequested)
        let saved = try await repository.card(id: card.id)
        XCTAssertNotNil(saved)
        let reopened = SyncSettingsModel(repository: repository, coordinator: sync)
        await reopened.load()
        XCTAssertEqual(reopened.conflicts.count, 1)
        XCTAssertEqual(reopened.unpresentedConflictCount, 0)

        let recovered = await reopened.recover(conflict.id)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(reopened.conflicts.first?.recoveredCardID, recovered)
        let recoveredCard = try await repository.card(id: recovered!)
        XCTAssertEqual(recoveredCard?.title, "Keep")

        let afterRecoveryRelaunch = SyncSettingsModel(repository: repository, coordinator: sync)
        await afterRecoveryRelaunch.load()
        XCTAssertEqual(afterRecoveryRelaunch.conflicts.first?.recoveredCardID, recovered)
        let repeatedRecovery = await afterRecoveryRelaunch.recover(conflict.id)
        XCTAssertEqual(repeatedRecovery, recovered)
    }

    func testSettingsFiltersExpiredConflictCopiesFromPersistentRecovery() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let capturedAt = Date(timeIntervalSince1970: 100)
        let card = try await repository.createCard(title: "Expired", now: capturedAt)
        _ = try await repository.captureConflict(cardID: card.id, lineID: nil,
            losingPayload: try JSONEncoder().encode(card), now: capturedAt)
        let sync = CloudSyncCoordinator(repository: repository, transport: SettingsCloudTransport())
        let model = SyncSettingsModel(repository: repository, coordinator: sync)

        await model.load(now: capturedAt.addingTimeInterval(2_592_001))

        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(model.unpresentedConflictCount, 0)
    }

    func testBackgroundSyncDefersConflictNoticeUntilSettingsLoads() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let card = try await repository.createCard(title: "Late conflict", now: .now)
        let sync = CloudSyncCoordinator(repository: repository, transport: SettingsCloudTransport())
        let model = SyncSettingsModel(repository: repository, coordinator: sync)
        await model.load()
        XCTAssertTrue(model.conflicts.isEmpty)

        _ = try await repository.captureConflict(cardID: card.id, lineID: nil,
            losingPayload: try JSONEncoder().encode(card), now: .now)
        await model.sync(.userRequested)

        XCTAssertEqual(model.conflicts.count, 1)
        XCTAssertEqual(model.unpresentedConflictCount, 0)
        await model.load()
        XCTAssertEqual(model.unpresentedConflictCount, 1)
        await model.load()
        XCTAssertEqual(model.unpresentedConflictCount, 1)
    }

    func testBackgroundSyncPreservesConflictNoticeAcrossRelaunchBeforeSettingsOpens() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let card = try await repository.createCard(title: "Relaunch conflict", now: .now)
        let sync = CloudSyncCoordinator(repository: repository, transport: SettingsCloudTransport())
        let backgroundModel = SyncSettingsModel(repository: repository, coordinator: sync)
        await backgroundModel.load()
        _ = try await repository.captureConflict(cardID: card.id, lineID: nil,
            losingPayload: try JSONEncoder().encode(card), now: .now)

        await backgroundModel.sync(.push)
        XCTAssertEqual(backgroundModel.unpresentedConflictCount, 0)
        let relaunched = SyncSettingsModel(repository: repository, coordinator: sync)
        await relaunched.load()

        XCTAssertEqual(relaunched.conflicts.count, 1)
        XCTAssertEqual(relaunched.unpresentedConflictCount, 1)
    }
}
