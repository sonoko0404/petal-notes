import Foundation
import PetalCore
import PetalPersistence

enum DeepLinkError: LocalizedError {
    case invalidLink, unavailable, cannotOpen, captureInProgress
    var errorDescription: String? {
        switch self {
        case .invalidLink: String(localized: "ui.this_petal_link_is_invalid.9ee568")
        case .unavailable: String(localized: "ui.this_card_is_unavailable_choose_a_card_in_petal.320ac9")
        case .cannotOpen: String(localized: "ui.unable_to_open_this_card_your_draft_has_been_kept_pleas.6a8ec4")
        case .captureInProgress: String(localized: "ui.finish_or_cancel_the_current_quick_add_before_opening_a.78682c")
        }
    }
}

@MainActor
struct DeepLinkHandler {
    let router: AppRouter
    let presentCapture: @MainActor (CardID) throws -> Void

    func handle(_ url: URL) async {
        guard let route = PetalDeepLink(url: url) else {
            await router.rejectDeepLink(.invalidLink)
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
