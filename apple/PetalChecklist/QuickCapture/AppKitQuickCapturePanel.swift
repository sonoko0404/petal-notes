import AppKit
import SwiftUI

struct ForegroundApplicationIdentity: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let launchDate: Date

    init(pid: pid_t, bundleIdentifier: String?, launchDate: Date) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    init?(_ application: NSRunningApplication) {
        guard let launchDate = application.launchDate else { return nil }
        self.init(pid: application.processIdentifier,
                  bundleIdentifier: application.bundleIdentifier,
                  launchDate: launchDate)
    }
}

@MainActor
final class WorkspaceForegroundClient: QuickCaptureForegroundClient {
    private var remembered: [pid_t: ForegroundApplicationIdentity] = [:]

    func currentPID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        if let identity = ForegroundApplicationIdentity(application) {
            remembered[identity.pid] = identity
        }
        return application.processIdentifier
    }

    static func canRestore(expected: ForegroundApplicationIdentity,
                           actual: ForegroundApplicationIdentity) -> Bool {
        expected == actual
    }

    func restore(pid: pid_t) {
        guard let expected = remembered.removeValue(forKey: pid),
              let application = NSRunningApplication(processIdentifier: pid),
              let actual = ForegroundApplicationIdentity(application),
              Self.canRestore(expected: expected, actual: actual) else { return }
        application.activate(options: [])
    }
}

@MainActor
final class AppKitQuickCapturePanel: NSObject, QuickCapturePanelClient, NSWindowDelegate {
    private var panel: NSPanel?
    var onSubmit: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    func show(model: QuickCaptureModel, onFirstResponder: @escaping () -> Void) {
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 462, height: 320),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            created.title = String(localized: "ui.quick_capture.3fb707")
            created.isFloatingPanel = true
            created.level = .floating
            created.hidesOnDeactivate = true
            created.isReleasedWhenClosed = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.delegate = self
            panel = created
            window = created
        }
        window.contentView = NSHostingView(rootView: QuickCaptureView(
            model: model,
            onSubmit: { [weak self] in self?.onSubmit?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onFirstResponder: onFirstResponder
        ))
        window.center()
        focus()
    }

    func focus() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { panel?.orderOut(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel?()
        return false
    }
}
