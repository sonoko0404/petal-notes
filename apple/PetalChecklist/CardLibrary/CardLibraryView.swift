import SwiftUI
import PetalCore

struct CardLibraryView: View {
    let model: CardLibraryModel
    let selectedCardID: CardID?
    let onSelect: (CardID) -> Void
    let onCreate: () -> Void
    let onRestore: (CardID) -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(scopeName(model.scope)).font(.headline)
                Spacer()
                Button(action: onCreate) { Image(systemName: "plus") }
                    .accessibilityLabel(Text("New Card"))
                    .accessibilityIdentifier("card.create")
            }.padding()
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("library.search")
                .padding(.horizontal)
                .onChange(of: searchText) { _, value in
                    Task { try? await model.search(value) }
                }
            List {
                if !searchText.isEmpty {
                    ForEach(model.searchResults) { item in
                        Button { onSelect(item.result.cardID) } label: {
                            VStack(alignment: .leading) {
                                Text(item.result.title)
                                Text(item.result.snippet).font(.caption).foregroundStyle(.secondary)
                                Text(scopeName(item.scope)).font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("scopeLabel.\(item.scope.rawValue)")
                            }
                        }
                    }
                } else {
                    ForEach(model.cards) { card in
                        HStack {
                            Button { onSelect(card.id) } label: { Text(card.title) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("card.select.\(card.id.rawValue)")
                            Spacer()
                            if card.status != .active {
                                Button("Restore") { onRestore(card.id) }
                                    .accessibilityIdentifier("card.restore")
                            }
                        }
                        .listRowBackground(selectedCardID == card.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
            }
            .accessibilityIdentifier("library.cards")
        }
        .onChange(of: model.scope) { _, _ in searchText = "" }
    }
}

func scopeName(_ scope: LibraryScope) -> LocalizedStringKey {
    switch scope {
    case .inbox: "Inbox"
    case .allCards: "All Cards"
    case .archive: "Archive"
    case .trash: "Trash"
    case .settings: "Settings"
    }
}
