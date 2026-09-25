import AppKit
import Observation
import PetalCore
import PetalPersistence

@MainActor @Observable
final class QuickCaptureAppController {
    let hotKey: GlobalHotKeyClient
    @ObservationIgnored private let panel = AppKitQuickCapturePanel()
    @ObservationIgnored private let foreground = WorkspaceForegroundClient()
    @ObservationIgnored private var coordinator: QuickCaptureCoordinator?
    @ObservationIgnored private var pendingTarget: CardID?
    @ObservationIgnored private var hasPendingPresentation = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = arguments.contains("-ui-testing")
            ? (UserDefaults(suiteName: "com.petalchecklist.mac.uitest.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard)
            : .standard
        hotKey = GlobalHotKeyClient(registrar: CarbonHotKeyRegistrar(), defaults: defaults)
    }

    func configure(repository: any PetalRepository,
                   onCommitted: @escaping @MainActor (CardID) async -> Void) {
        guard coordinator == nil else { return }
        let capture = QuickCaptureCoordinator(
            repository: repository, panel: panel, foreground: foreground,
            currentPID: ProcessInfo.processInfo.processIdentifier,
            clock: { ProcessInfo.processInfo.systemUptime },
            onCommitted: onCommitted
        )
        coordinator = capture
        panel.onSubmit = { [weak self] in
            Task { @MainActor in await self?.coordinator?.submit() }
        }
        panel.onCancel = { [weak self] in self?.coordinator?.cancel() }
        hotKey.onPress = { [weak self] in self?.present(targetCardID: nil) }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-enable-hotkey") {
            hotKey.configure(.optionCommandN)
        } else if !arguments.contains("-ui-testing") {
            hotKey.start()
        }
        if hasPendingPresentation {
            capture.present(targetCardID: pendingTarget)
            hasPendingPresentation = false
            pendingTarget = nil
        }
    }

    func present(targetCardID: CardID?) {
        guard let coordinator else {
            pendingTarget = targetCardID
            hasPendingPresentation = true
            return
        }
        coordinator.present(targetCardID: targetCardID)
    }

    func openFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-open-quick-capture") else { return }
        if let position = arguments.firstIndex(of: "-quick-capture-card"),
           arguments.indices.contains(position + 1),
           let uuid = UUID(uuidString: arguments[position + 1]) {
            present(targetCardID: CardID(rawValue: uuid))
        } else {
            present(targetCardID: nil)
        }
    }

    func presentFromDeepLink(targetCardID: CardID) throws {
        guard let coordinator else { throw DeepLinkError.cannotOpen }
        try coordinator.presentFromDeepLink(targetCardID: targetCardID)
    }

    static func cardTarget(for url: URL) -> CardID? {
        guard case .quickAdd(let id) = PetalDeepLink(url: url) else { return nil }
        return id
    }
}
