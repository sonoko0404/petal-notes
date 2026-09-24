import SwiftUI
import PetalCore

struct CardLibraryView: View {
    let model: CardLibraryModel
    let selectedCardID: CardID?
    let onSelect: (CardID) -> Void
    let onCreate: () -> Void
    let onRestore: (CardID) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(scopeName(model.scope)).font(.headline)
                Spacer()
                Button(action: onCreate) { Image(systemName: "plus") }
                    .accessibilityLabel(Text("ui.new_card.df1e64"))
                    .accessibilityIdentifier("card.create")
            }.padding()
            TextField("ui.search.49c266", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("library.search")
                .padding(.horizontal)
            if let errorMessage = model.errorMessage {
                HStack {
                    Text(errorMessage)
                    Button("ui.retry.942087") { Task { await model.retryQuery() } }
                        .accessibilityIdentifier("library.retry")
                }
                .padding(.horizontal)
                .accessibilityIdentifier("library.error")
            }
            List {
                if !model.query.isEmpty {
                    ForEach(model.searchResults) { item in
                        HStack {
                            Button { onSelect(item.result.cardID) } label: {
                            VStack(alignment: .leading) {
                                Text(item.result.title)
                                Text(item.result.snippet).font(.caption).foregroundStyle(.secondary)
                                Text(scopeName(item.scope)).font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("scopeLabel.\(item.scope.rawValue)")
                            }
                            }
                            if item.scope == .archive || item.scope == .trash {
                                Button("ui.restore.a76e13") { onRestore(item.result.cardID) }
                                    .accessibilityIdentifier("card.restore")
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
                                Button("ui.restore.a76e13") { onRestore(card.id) }
                                    .accessibilityIdentifier("card.restore")
                            }
                        }
                        .listRowBackground(selectedCardID == card.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
            }
            .accessibilityIdentifier("library.cards")
        }
    }
}

func scopeName(_ scope: LibraryScope) -> LocalizedStringKey {
    switch scope {
    case .inbox: "ui.inbox.94835e"
    case .allCards: "ui.all_cards.c98ee6"
    case .archive: "ui.archive.66f480"
    case .trash: "ui.trash.c56012"
    case .settings: "ui.settings.74a883"
    }
}
