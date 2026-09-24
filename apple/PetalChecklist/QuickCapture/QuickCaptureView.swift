import AppKit
import SwiftUI

enum QuickCaptureKeyAction: Equatable {
    case submit, newline, cancel, ordinary
    static func action(keyCode: UInt16, shift: Bool) -> Self {
        switch keyCode {
        case 36, 76: shift ? .newline : .submit
        case 53: .cancel
        default: .ordinary
        }
    }
}

struct QuickCaptureView: View {
    let model: QuickCaptureModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFirstResponder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Capture").font(.headline)
            CaptureTextEditor(model: model, onSubmit: onSubmit, onCancel: onCancel,
                              onFirstResponder: onFirstResponder)
                .frame(height: 110)
                .accessibilityIdentifier("quickCapture.text")
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               let milliseconds = model.focusLatencyMilliseconds {
                Text(String(format: "%.3f", milliseconds))
                    .accessibilityIdentifier("quickCapture.focusLatencyMs")
            }
            if let notice = model.targetNotice {
                Text(notice).foregroundStyle(.orange)
                    .accessibilityIdentifier("quickCapture.targetNotice")
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("quickCapture.error")
            }
            HStack {
                Text("Shift+Return for a new line")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("quickCapture.cancel")
                Button("Add", action: onSubmit)
                    .disabled(model.isSubmitting || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quickCapture.submit")
            }
        }
        .padding(16)
        .frame(width: 430)
    }
}

private struct CaptureTextEditor: NSViewRepresentable {
    let model: QuickCaptureModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFirstResponder: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = CaptureNSTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 6, height: 7)
        editor.setAccessibilityIdentifier("quickCapture.text")
        editor.delegate = context.coordinator
        editor.onKey = { action in
            switch action {
            case .submit: onSubmit()
            case .cancel: onCancel()
            case .newline, .ordinary: break
            }
        }
        editor.onFirstResponder = onFirstResponder
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CaptureNSTextView else { return }
        context.coordinator.model = model
        if editor.string != model.text { editor.string = model.text }
        editor.onKey = { action in
            switch action {
            case .submit: onSubmit()
            case .cancel: onCancel()
            case .newline, .ordinary: break
            }
        }
        editor.onFirstResponder = onFirstResponder
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: QuickCaptureModel
        init(model: QuickCaptureModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            model.edit(editor.string)
        }
    }
}

final class CaptureNSTextView: NSTextView {
    var onKey: ((QuickCaptureKeyAction) -> Void)?
    var onFirstResponder: (() -> Void)?
    private var hasReportedFocus = false

    override func keyDown(with event: NSEvent) {
        dispatchKey(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift),
                    markedText: hasMarkedText(),
                    passThrough: { super.keyDown(with: event) },
                    insertNewline: { self.insertText("\n", replacementRange: self.selectedRange()) })
    }

    func dispatchKey(keyCode: UInt16, shift: Bool, markedText: Bool,
                     passThrough: () -> Void, insertNewline: () -> Void) {
        if markedText && (keyCode == 36 || keyCode == 76 || keyCode == 53) {
            passThrough()
            return
        }
        let action = QuickCaptureKeyAction.action(keyCode: keyCode, shift: shift)
        switch action {
        case .submit, .cancel: onKey?(action)
        case .newline: insertNewline()
        case .ordinary: passThrough()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became && !hasReportedFocus {
            hasReportedFocus = true
            onFirstResponder?()
        }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
