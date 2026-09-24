import Foundation
import OSLog
import PetalCore
import PetalPersistence

@MainActor
protocol QuickCapturePanelClient: AnyObject {
    func show(model: QuickCaptureModel, onFirstResponder: @escaping () -> Void)
    func focus()
    func hide()
}

@MainActor
protocol QuickCaptureForegroundClient: AnyObject {
    func currentPID() -> pid_t?
    func restore(pid: pid_t)
}

@MainActor
final class QuickCaptureCoordinator {
    private let repository: any PetalRepository
    private let panel: any QuickCapturePanelClient
    private let foreground: any QuickCaptureForegroundClient
    private let currentPID: pid_t
    private let clock: () -> TimeInterval
    private let onCommitted: (@MainActor (CardID) async -> Void)?
    private let logger = Logger(subsystem: "com.petalchecklist.mac", category: "QuickCapture")
    private var previousPID: pid_t?
    private var invocationTime: TimeInterval?
    private(set) var model: QuickCaptureModel?
    private(set) var lastFocusLatency: TimeInterval?
    private(set) var focusBudgetMet: Bool?

    init(repository: any PetalRepository, panel: any QuickCapturePanelClient,
         foreground: any QuickCaptureForegroundClient, currentPID: pid_t,
         clock: @escaping () -> TimeInterval,
         onCommitted: (@MainActor (CardID) async -> Void)? = nil) {
        self.repository = repository
        self.panel = panel
        self.foreground = foreground
        self.currentPID = currentPID
        self.clock = clock
        self.onCommitted = onCommitted
    }

    func present(targetCardID: CardID?) {
        if model != nil {
            if let frontmost = foreground.currentPID(), frontmost != currentPID {
                previousPID = frontmost
            }
            panel.focus()
            return
        }
        let frontmost = foreground.currentPID()
        previousPID = frontmost == currentPID ? nil : frontmost
        invocationTime = clock()
        let target: QuickCaptureTarget = targetCardID.map { .card($0) } ?? .inbox
        let capture = QuickCaptureModel(repository: repository, target: target)
        model = capture
        panel.show(model: capture) { [weak self] in
            guard let self, let invocationTime = self.invocationTime else { return }
            let latency = self.clock() - invocationTime
            self.lastFocusLatency = latency
            self.focusBudgetMet = latency <= 0.300
            capture.recordFocusLatency(latency)
            self.logger.info("Invocation to first responder: \(latency, privacy: .public) seconds")
            self.invocationTime = nil
        }
    }

    func submit() async {
        guard let current = model, !current.isSubmitting, !current.shouldClose else { return }
        await current.submit()
        if let cardID = current.lastCommittedCardID {
            await onCommitted?(cardID)
        }
        if current.shouldClose, model === current { dismiss() }
    }

    func cancel() {
        guard model?.isSubmitting == false else { return }
        dismiss()
    }

    private func dismiss() {
        guard model != nil else { return }
        panel.hide()
        model = nil
        invocationTime = nil
        if let previousPID, foreground.currentPID() == currentPID {
            foreground.restore(pid: previousPID)
        }
        previousPID = nil
    }
}
