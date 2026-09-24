import SwiftUI
import UniformTypeIdentifiers
import PetalCore

struct CardLineRow: View {
    let line: CardLine
    let model: CardEditorModel
    let onError: (Error) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if line.kind == .todo {
                Button {
                    Task { do { try await model.setCompleted(lineID: line.id, completed: !line.isCompleted) }
                        catch { onError(error) } }
                } label: { Image(systemName: line.isCompleted ? "checkmark.circle.fill" : "circle") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line.isCompleted ? Text("Mark Incomplete") : Text("Complete Todo"))
                    .accessibilityIdentifier(line.isCompleted ? "line.incomplete" : "line.complete")
            } else {
                Image(systemName: "text.alignleft").accessibilityHidden(true)
            }
            TextField(line.kind == .todo ? "Todo" : "Text", text: Binding(
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
                Button(line.kind == .todo ? "Convert to Text" : "Convert to Todo") {
                    Task { do { try await model.convert(lineID: line.id, to: line.kind == .todo ? .text : .todo) }
                        catch { onError(error) } }
                }
                .accessibilityIdentifier(line.kind == .todo ? "line.convertToText" : "line.convertToTodo")
                Button("Move Up") { move(.up) }.accessibilityIdentifier("line.moveUp")
                Button("Move Down") { move(.down) }.accessibilityIdentifier("line.moveDown")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text("Line Actions"))
            }
            .accessibilityIdentifier(line.kind == .todo ? "line.kind.todo" : "line.kind.text")
        }
        .onMoveCommand { direction in
            if let moveDirection = Self.moveDirection(for: direction) { move(moveDirection) }
        }
        .onDrag { NSItemProvider(object: line.id.rawValue.uuidString as NSString) }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String, let uuid = UUID(uuidString: raw) else { return }
                Task { @MainActor in
                    var ids = model.lines.map(\.id)
                    guard let source = ids.firstIndex(of: LineID(rawValue: uuid)),
                          let destination = ids.firstIndex(of: line.id) else { return }
                    ids.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
                    do { try await model.reorder(orderedLineIDs: ids) } catch { onError(error) }
                }
            }
            return true
        }
    }

    private func move(_ direction: MoveDirection) {
        Task { do { try await model.move(lineID: line.id, direction: direction) } catch { onError(error) } }
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
