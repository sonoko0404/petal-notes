import Observation
import PetalCore

enum LibraryScope: String, CaseIterable, Identifiable {
    case inbox, allCards, archive, trash, settings

    var id: Self { self }
}

@MainActor @Observable
final class AppRouter {
    var scope: LibraryScope = .inbox
    var selectedCardID: CardID?
}
