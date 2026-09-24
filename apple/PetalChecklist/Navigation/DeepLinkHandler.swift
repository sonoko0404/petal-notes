import Foundation
import PetalCore
import PetalPersistence

enum DeepLinkError: LocalizedError {
    case invalidLink, unavailable, cannotOpen, captureInProgress
    var errorDescription: String? {
        switch self {
        case .invalidLink: String(localized: "This Petal link is invalid.")
        case .unavailable: String(localized: "This card is unavailable. Choose a card in Petal.")
        case .cannotOpen: String(localized: "Unable to open this card. Your draft has been kept. Please try again.")
        case .captureInProgress: String(localized: "Finish or cancel the current quick add before opening another card.")
        }
    }
}

@MainActor
struct DeepLinkHandler {
    let router: AppRouter
    let presentCapture: @MainActor (CardID) throws -> Void

    func handle(_ url: URL) async {
        guard let route = PetalDeepLink(url: url) else {
            router.present(DeepLinkError.invalidLink) { await handle(url) }
            return
        }
        await router.follow(route, presentCapture: presentCapture)
    }

    static func validate(_ route: PetalDeepLink, repository: any PetalRepository) async throws -> Card {
        guard let card = try await repository.card(id: route.cardID), card.status != .trashed else {
            throw DeepLinkError.unavailable
        }
        if case .quickAdd = route, card.status != .active { throw DeepLinkError.unavailable }
        return card
    }
}
