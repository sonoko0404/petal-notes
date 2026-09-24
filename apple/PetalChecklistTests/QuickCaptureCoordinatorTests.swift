import XCTest
import PetalCore
import PetalTestSupport
@testable import PetalChecklist

@MainActor
final class QuickCaptureCoordinatorTests: XCTestCase {
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
}
