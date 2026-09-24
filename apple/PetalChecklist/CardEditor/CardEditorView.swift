import SwiftUI
import PetalCore

struct CardEditorView: View {
    let model: CardEditorModel
    let onArchive: () -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isReadOnly {
                HStack {
                    Text(model.title).font(.title2).accessibilityIdentifier("editor.title.readOnly")
                    Spacer()
                    Button("Restore", action: onRestore).accessibilityIdentifier("editor.restore")
                }
                Text("In Trash").foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Card title", text: Binding(get: { model.title }, set: { model.editTitle($0) }))
                        .font(.title2)
                        .accessibilityIdentifier("editor.title")
                    Button("Archive", action: onArchive).accessibilityIdentifier("card.archive")
                    Button("Trash", action: onTrash).accessibilityIdentifier("card.trash")
                }
            }
            if case .failed(let message) = model.saveState {
                HStack {
                    Text("Save failed: \(message)").foregroundStyle(.red)
                    Button("Retry") { Task { _ = await model.retry() } }
                        .accessibilityIdentifier("editor.retry")
                }
                .accessibilityIdentifier("editor.saveError")
            }
            if let actionError { Text(actionError).foregroundStyle(.red) }
            List {
                ForEach(model.lines) { line in
                    CardLineRow(line: line, model: model) { actionError = $0.localizedDescription }
                        .disabled(model.isReadOnly)
                }
            }
            .accessibilityIdentifier("editor.lines")
            if !model.isReadOnly {
                if let newLineError = model.newLineError {
                    HStack {
                        Text(newLineError).foregroundStyle(.red)
                        Button("Retry", action: addLine).accessibilityIdentifier("editor.newLineRetry")
                    }
                }
                HStack {
                    TextField("New todo", text: Binding(get: { model.newLineDraft }, set: { model.editNewLine($0) }))
                        .accessibilityIdentifier("editor.newLine")
                        .onSubmit(addLine)
                    Button("Add Todo", action: addLine)
                        .accessibilityIdentifier("editor.addLine")
                        .disabled(model.isAddingLine)
                }
            }
        }
        .padding()
    }

    private func addLine() {
        Task {
            do { _ = try await model.submitNewLine(); actionError = nil }
            catch { actionError = error.localizedDescription }
        }
    }
}
