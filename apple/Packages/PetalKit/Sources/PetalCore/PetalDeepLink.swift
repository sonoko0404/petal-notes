import Foundation

public enum PetalDeepLink: Equatable, Sendable {
    case card(CardID), quickAdd(CardID)

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "petal", parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.count == 37, parts.path.first == "/",
              let id = UUID(uuidString: String(parts.path.dropFirst())) else { return nil }
        switch parts.host {
        case "card": self = .card(CardID(rawValue: id))
        case "quick-add": self = .quickAdd(CardID(rawValue: id))
        default: return nil
        }
    }

    public var cardID: CardID {
        switch self { case .card(let id), .quickAdd(let id): id }
    }
    public var url: URL {
        let host: String = switch self { case .card: "card"; case .quickAdd: "quick-add" }
        return URL(string: "petal://\(host)/\(cardID.rawValue.uuidString)")!
    }
}
