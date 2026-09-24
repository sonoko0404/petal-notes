import SwiftUI
import PetalCore

struct CardEditorView: View {
    let model: CardEditorModel
    let onArchive: () -> Void
    let onTrash: () -> Void
    @State private var newLine = ""
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Card title", text: Binding(get: { model.title }, set: { model.editTitle($0) }))
                    .font(.title2)
                    .accessibilityIdentifier("editor.title")
                Button("Archive", action: onArchive).accessibilityIdentifier("card.archive")
                Button("Trash", action: onTrash).accessibilityIdentifier("card.trash")
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
                }
            }
            .accessibilityIdentifier("editor.lines")
            HStack {
                TextField("New todo", text: $newLine)
                    .accessibilityIdentifier("editor.newLine")
                    .onSubmit(addLine)
                Button("Add Todo", action: addLine).accessibilityIdentifier("editor.addLine")
            }
        }
        .padding()
    }

    private func addLine() {
        let draft = newLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        Task {
            do { try await model.addLine(text: draft); newLine = "" }
            catch { actionError = error.localizedDescription }
        }
    }
}
