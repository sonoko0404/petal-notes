import AppKit
import SwiftUI

@MainActor
final class WorkspaceForegroundClient: QuickCaptureForegroundClient {
    func currentPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func restore(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
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
            created.title = String(localized: "Quick Capture")
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
