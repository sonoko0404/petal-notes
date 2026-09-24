import AppIntents
import PetalCore

/// Compiled into both App and extension. Foreground execution uses the App's
/// registered router; no extension-to-App module import or macOS 15 API is needed.
struct OpenCardIntent: AppIntent {
    static let title = LocalizedStringResource("Open Card", table: "Widgets")
    static let openAppWhenRun = true
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("Card", table: "Widgets")) var card: CardEntity
    init() {}
    init(cardID: CardID) { card = CardEntity(id: cardID.rawValue, title: nil) }
    @MainActor func perform() async throws -> some IntentResult {
        await perform(navigation: .shared)
        return .result()
    }
    @MainActor func perform(navigation: PetalNavigationRequests) async {
        await navigation.open(PetalDeepLink.card(CardID(rawValue: card.id)).url)
    }
}
