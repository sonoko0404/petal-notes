import SwiftUI
import UniformTypeIdentifiers
import PetalCore

struct CardLineRow: View {
    let line: CardLine
    let effectiveCompleted: Bool
    let allowsReordering: Bool
    let model: CardEditorModel
    let onError: (Error) -> Void
    @FocusState private var focused: Bool
    @State private var editingReminder = false

    var body: some View {
        HStack {
            if line.kind == .todo {
                Button {
                    Task { do { try await model.setCompleted(lineID: line.id, completed: !effectiveCompleted) }
                        catch { onError(error) } }
                } label: {
                    Image(systemName: effectiveCompleted ? "checkmark.circle.fill" : "circle")
                        .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(effectiveCompleted ? Text("ui.mark_incomplete.331426") : Text("ui.complete_todo.70bfc6"))
                    .accessibilityValue(effectiveCompleted ? Text("ui.completed.22a970", tableName: "Widgets") : Text("ui.incomplete.75f33c", tableName: "Widgets"))
                    .accessibilityIdentifier(effectiveCompleted ? "line.incomplete" : "line.complete")
            } else {
                Image(systemName: "text.alignleft").accessibilityHidden(true)
            }
            TextField(line.kind == .todo ? String(localized: "ui.todo.4ff402") : String(localized: "ui.text.71988c"), text: Binding(
                get: { model.unsavedText[line.id] ?? line.text },
                set: { model.editText(lineID: line.id, text: $0) }
            ))
            .focused($focused)
            .accessibilityIdentifier("line.text.\(line.id.rawValue)")
            .onKeyPress(.upArrow, phases: .down) { press in
                guard press.modifiers.contains(.command), press.modifiers.contains(.option) else { return .ignored }
                move(.up)
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                guard press.modifiers.contains(.command), press.modifiers.contains(.option) else { return .ignored }
                move(.down)
                return .handled
            }
            Menu {
                if line.kind == .todo {
                    Button("ui.reminder.31757b") { editingReminder = true }
                        .accessibilityIdentifier("line.reminder")
                }
                Button(line.kind == .todo ? String(localized: "ui.convert_to_text.90a386") : String(localized: "ui.convert_to_todo.50fc20")) {
                    Task { do { try await model.convert(lineID: line.id, to: line.kind == .todo ? .text : .todo) }
                        catch { onError(error) } }
                }
                .accessibilityIdentifier(line.kind == .todo ? "line.convertToText" : "line.convertToTodo")
                if allowsReordering {
                    Button("ui.move_up.135962") { move(.up) }.accessibilityIdentifier("line.moveUp")
                    Button("ui.move_down.b58330") { move(.down) }.accessibilityIdentifier("line.moveDown")
                }
                Divider()
                Button("ui.delete_row.41b5e8", role: .destructive, action: delete)
                    .accessibilityIdentifier("line.delete")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("ui.line_actions.336265"))
            .accessibilityValue(line.kind == .todo ? Text("ui.todo.4ff402") : Text("ui.text.71988c"))
            .accessibilityIdentifier(line.kind == .todo ? "line.kind.todo" : "line.kind.text")
        }
        .onMoveCommand { direction in
            if allowsReordering, let moveDirection = Self.moveDirection(for: direction) { move(moveDirection) }
        }
        .onDeleteCommand(perform: delete)
        .sheet(isPresented: $editingReminder) { ReminderEditorView(line: line, model: model) }
        .onDrag { NSItemProvider(object: line.id.rawValue.uuidString as NSString) }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
            guard allowsReordering else { return false }
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String, let uuid = UUID(uuidString: raw) else { return }
                Task { @MainActor in
                    var ids = model.incompleteLines.map(\.id)
                    guard let source = ids.firstIndex(of: LineID(rawValue: uuid)),
                          let destination = ids.firstIndex(of: line.id) else { return }
                    ids.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
                    do { try await model.reorderIncomplete(orderedLineIDs: ids) } catch { onError(error) }
                }
            }
            return true
        }
    }

    private func move(_ direction: MoveDirection) {
        Task { do { try await model.move(lineID: line.id, direction: direction) } catch { onError(error) } }
    }

    private func delete() {
        Task { do { try await model.delete(lineID: line.id) } catch { onError(error) } }
    }

    static func moveDirection(for direction: MoveCommandDirection) -> MoveDirection? {
        switch direction {
        case .up: .up
        case .down: .down
        case .left, .right: nil
        @unknown default: nil
        }
    }
}
