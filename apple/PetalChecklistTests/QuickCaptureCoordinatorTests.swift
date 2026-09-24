import XCTest
import PetalCore
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class QuickCaptureCoordinatorTests: XCTestCase {
    func testDeepLinkCannotRetargetAnExistingDraftOrFallBackAfterArchive() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let a = try await repository.createCard(title: "A", now: .now)
        let b = try await repository.createCard(title: "B", now: .now)
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: Panel(), foreground: Foreground(), currentPID: 999, clock: { 0 })
        try coordinator.presentFromDeepLink(targetCardID: a.id)
        coordinator.model?.edit("Keep target")
        XCTAssertThrowsError(try coordinator.presentFromDeepLink(targetCardID: b.id))
        XCTAssertEqual(coordinator.model?.target, .card(a.id))
        XCTAssertEqual(coordinator.model?.text, "Keep target")
        try await repository.moveCard(a.id, to: .archived, replacementInbox: nil, now: .now)
        await coordinator.submit()
        await coordinator.submit()
        XCTAssertEqual(coordinator.model?.text, "Keep target")
        XCTAssertNotNil(coordinator.model?.errorMessage)
        let inboxes = try await repository.cards(scope: .active)
        let inbox = try XCTUnwrap(inboxes.first(where: \.isInbox))
        let lines = try await repository.lines(cardID: inbox.id)
        XCTAssertTrue(lines.isEmpty)
    }

    func testDeepLinkMakesExistingSameTargetDraftStrict() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let card = try await repository.createCard(title: "A", now: .now)
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: Panel(), foreground: Foreground(), currentPID: 999, clock: { 0 })
        coordinator.present(targetCardID: card.id)
        coordinator.model?.edit("Original draft")
        try coordinator.presentFromDeepLink(targetCardID: card.id)
        try await repository.moveCard(card.id, to: .archived, replacementInbox: nil, now: .now)
        await coordinator.submit()
        await coordinator.submit()
        XCTAssertEqual(coordinator.model?.text, "Original draft")
        XCTAssertNotNil(coordinator.model?.errorMessage)
    }

    private final class Panel: QuickCapturePanelClient {
        var showCount = 0
        var focusCount = 0
        var hideCount = 0
        var onFirstResponder: (() -> Void)?
        func show(model: QuickCaptureModel, onFirstResponder: @escaping () -> Void) {
            showCount += 1
            self.onFirstResponder = onFirstResponder
        }
        func focus() { focusCount += 1 }
        func hide() { hideCount += 1 }
    }

    private final class Foreground: QuickCaptureForegroundClient {
        var frontmostPID: pid_t? = 1234
        var restored: [pid_t] = []
        func currentPID() -> pid_t? { frontmostPID }
        func restore(pid: pid_t) { restored.append(pid) }
    }

    func testRepeatedInvocationKeepsDraftAndRestoresOriginalForegroundOnCancel() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let panel = Panel()
        let foreground = Foreground()
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: panel, foreground: foreground,
                                                  currentPID: 999, clock: { 0 })
        coordinator.present(targetCardID: nil)
        coordinator.model?.edit("Unsent")
        foreground.frontmostPID = 999
        coordinator.present(targetCardID: CardID(rawValue: UUID()))
        XCTAssertEqual(panel.showCount, 1)
        XCTAssertEqual(panel.focusCount, 1)
        XCTAssertEqual(coordinator.model?.text, "Unsent")
        coordinator.cancel()
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(foreground.restored, [1234])
    }

    func testSuccessDismissesAndFirstResponderLatencyIsMeasured() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let panel = Panel()
        let foreground = Foreground()
        var time = 10.0
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: panel, foreground: foreground,
                                                  currentPID: 999, clock: { time })
        coordinator.present(targetCardID: nil)
        time = 10.14
        panel.onFirstResponder?()
        let latency = try XCTUnwrap(coordinator.lastFocusLatency)
        XCTAssertEqual(latency, 0.14, accuracy: 0.001)
        coordinator.model?.edit("Captured")
        foreground.frontmostPID = 999
        await coordinator.submit()
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(foreground.restored, [1234])
    }

    func testReinvocationAfterAppSwitchRestoresTheLatestForegroundApp() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let panel = Panel()
        let foreground = Foreground()
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: panel, foreground: foreground,
                                                  currentPID: 999, clock: { 0 })
        coordinator.present(targetCardID: nil)
        foreground.frontmostPID = 4567
        coordinator.present(targetCardID: nil)
        foreground.frontmostPID = 999
        coordinator.cancel()
        XCTAssertEqual(foreground.restored, [4567])
    }

    func testQuickAddDeepLinkParsesItsCardTarget() {
        let uuid = UUID(uuidString: "20F46FAB-23E3-4914-B0E0-5BE0CB39045F")!
        let url = URL(string: "petal://quick-add/20F46FAB-23E3-4914-B0E0-5BE0CB39045F")!
        XCTAssertEqual(QuickCaptureAppController.cardTarget(for: url)?.rawValue, uuid)
        XCTAssertNil(QuickCaptureAppController.cardTarget(for: URL(string: "petal://card/20F46FAB-23E3-4914-B0E0-5BE0CB39045F")!))
    }

    func testSuccessfulSubmissionPublishesCommittedCardForRefresh() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let active = try await repository.cards(scope: .active)
        let inbox = try XCTUnwrap(active.first(where: \.isInbox))
        let panel = Panel()
        let foreground = Foreground()
        var notified: [CardID] = []
        let coordinator = QuickCaptureCoordinator(
            repository: repository, panel: panel, foreground: foreground, currentPID: 999,
            clock: { 0 }, onCommitted: { notified.append($0) }
        )
        coordinator.present(targetCardID: nil)
        coordinator.model?.edit("Captured")
        await coordinator.submit()
        XCTAssertEqual(notified, [inbox.id])
        let lines = try await repository.lines(cardID: inbox.id)
        XCTAssertEqual(lines.map(\.text), ["Captured"])
    }

    func testFocusMeasurementFailsBudgetAboveThreeHundredMilliseconds() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let panel = Panel()
        let foreground = Foreground()
        var time = 10.0
        let coordinator = QuickCaptureCoordinator(repository: repository, panel: panel, foreground: foreground,
                                                  currentPID: 999, clock: { time })
        coordinator.present(targetCardID: nil)
        time = 10.301
        panel.onFirstResponder?()
        let latency = try XCTUnwrap(coordinator.lastFocusLatency)
        XCTAssertEqual(latency, 0.301, accuracy: 0.001)
        XCTAssertEqual(coordinator.focusBudgetMet, false)
        let milliseconds = try XCTUnwrap(coordinator.model?.focusLatencyMilliseconds)
        XCTAssertEqual(milliseconds, 301, accuracy: 0.1)
    }

    func testForegroundRestoreRejectsReusedPIDIdentity() {
        let launch = Date(timeIntervalSince1970: 100)
        let expected = ForegroundApplicationIdentity(pid: 1234, bundleIdentifier: "com.example.original", launchDate: launch)
        XCTAssertTrue(WorkspaceForegroundClient.canRestore(expected: expected, actual: expected))
        XCTAssertFalse(WorkspaceForegroundClient.canRestore(
            expected: expected,
            actual: ForegroundApplicationIdentity(pid: 1234, bundleIdentifier: "com.example.other", launchDate: launch)
        ))
        XCTAssertFalse(WorkspaceForegroundClient.canRestore(
            expected: expected,
            actual: ForegroundApplicationIdentity(pid: 1234, bundleIdentifier: "com.example.original", launchDate: launch.addingTimeInterval(1))
        ))
    }

    func testRepeatedSubmitDuringRefreshDoesNotRepublishCommittedCapture() async throws {
        let repository = try await InMemoryPetalRepository.bootstrapped()
        let panel = Panel()
        let foreground = Foreground()
        let gate = RepositoryGate()
        gate.pauseNext()
        var notifications = 0
        let coordinator = QuickCaptureCoordinator(
            repository: repository, panel: panel, foreground: foreground, currentPID: 999,
            clock: { 0 }, onCommitted: {
                _ = $0
                notifications += 1
                await gate.enter()
            }
        )
        coordinator.present(targetCardID: nil)
        coordinator.model?.edit("Only once")
        let first = Task { await coordinator.submit() }
        await gate.waitUntilEntered()
        await coordinator.submit()
        XCTAssertEqual(notifications, 1)
        gate.resume()
        await first.value
    }
}
