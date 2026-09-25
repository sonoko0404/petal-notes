import SwiftUI
import PetalCore
import PetalDesignSystem

struct CardEditorView: View {
    let model: CardEditorModel
    let onArchive: () -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    @State private var actionError: String?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance.theme") private var theme = "cream"
    @AppStorage("appearance.typeface") private var typeface = "standard"
    private var tokens: PetalThemeTokens {
        PetalTheme.tokens(id: ThemeID(rawValue: theme) ?? .cream, mode: colorScheme == .dark ? .dark : .light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isReadOnly {
                HStack {
                    Text(model.title).font(.title2).accessibilityIdentifier("editor.title.readOnly")
                    Spacer()
                    Button("ui.restore.a76e13", action: onRestore).accessibilityIdentifier("editor.restore")
                }
                Text("ui.in_trash.5693d1").foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("ui.card_title.03449f", text: Binding(get: { model.title }, set: { model.editTitle($0) }))
                        .font(.title2)
                        .accessibilityIdentifier("editor.title")
                    Button("ui.archive.66f480", action: onArchive).accessibilityIdentifier("card.archive")
                    Button("ui.trash.c56012", action: onTrash).accessibilityIdentifier("card.trash")
                }
            }
            if case .failed(let message) = model.saveState {
                HStack {
                    Text("ui.save_failed \(message)").foregroundStyle(.red)
                    Button("ui.retry.942087") { Task { _ = await model.retry() } }
                        .accessibilityIdentifier("editor.retry")
                }
                .accessibilityIdentifier("editor.saveError")
            }
            if let actionError { Text(actionError).foregroundStyle(.red) }
            List {
                Section {
                    ForEach(model.incompleteLines) { line in
                        CardLineRow(line: line, effectiveCompleted: model.isEffectivelyCompleted(line),
                                    allowsReordering: true, model: model) { actionError = PetalErrorCopy.message($0) }
                            .disabled(model.isReadOnly)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("ui.incomplete.75f33c", tableName: "Widgets")
                        .accessibilityIdentifier("editor.incompleteSection")
                }
                if !model.completedLines.isEmpty {
                    Section {
                        ForEach(model.completedLines) { line in
                            CardLineRow(line: line, effectiveCompleted: model.isEffectivelyCompleted(line),
                                        allowsReordering: false, model: model) { actionError = PetalErrorCopy.message($0) }
                                .disabled(model.isReadOnly)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("ui.completed.22a970", tableName: "Widgets")
                            .accessibilityIdentifier("editor.completedSection")
                    }
                }
            }
            .accessibilityIdentifier("editor.lines")
            .scrollContentBackground(.hidden)
            if !model.isReadOnly {
                if let newLineError = model.newLineError {
                    HStack {
                        Text(newLineError).foregroundStyle(.red)
                        Button("ui.retry.942087", action: addLine).accessibilityIdentifier("editor.newLineRetry")
                    }
                }
                HStack {
                    TextField("ui.new_todo.1ec858", text: Binding(get: { model.newLineDraft }, set: { model.editNewLine($0) }))
                        .accessibilityIdentifier("editor.newLine")
                        .onSubmit(addLine)
                    Button("ui.add_todo.b8c6b9", action: addLine)
                        .accessibilityIdentifier("editor.addLine")
                        .disabled(model.isAddingLine)
                }
            }
        }
        .padding()
        .font(.system(.body, design: PetalTypeface(rawValue: typeface)?.design ?? .default))
        .foregroundStyle(tokens.primary.color)
        .tint(tokens.focus.color)
        .background(tokens.surface.color)
    }

    private func addLine() {
        Task {
            do { _ = try await model.submitNewLine(); actionError = nil }
            catch { actionError = PetalErrorCopy.message(error) }
        }
    }
}
