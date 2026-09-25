import AppIntents
import PetalCore

struct QuickAddIntent: AppIntent {
    static let title = LocalizedStringResource("ui.quick_add_to_card.435da3", table: "Widgets")
    static let openAppWhenRun = true
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("ui.card.be3702", table: "Widgets")) var card: CardEntity
    init() {}
    init(cardID: CardID) { card = CardEntity(id: cardID.rawValue, title: nil) }
    @MainActor func perform() async throws -> some IntentResult {
        await perform(navigation: .shared)
        return .result()
    }
    @MainActor func perform(navigation: PetalNavigationRequests) async {
        await navigation.open(PetalDeepLink.quickAdd(CardID(rawValue: card.id)).url)
    }
}
