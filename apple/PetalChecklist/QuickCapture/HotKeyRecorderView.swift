import AppKit
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    let onCapture: (HotKeyChoice) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.setAccessibilityIdentifier("settings.hotKeyRecorder")
        view.setAccessibilityLabel(String(localized: "Press a shortcut with Command, Option, or Control"))
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCapture: ((HotKeyChoice) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
            } else if let choice = HotKeyChoice.recorded(
                keyCode: event.keyCode, flags: event.modifierFlags,
                characters: event.charactersIgnoringModifiers ?? ""
            ) {
                onCapture?(choice)
            } else {
                NSSound.beep()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
