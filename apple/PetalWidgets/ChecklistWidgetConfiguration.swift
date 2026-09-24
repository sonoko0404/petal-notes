import AppIntents
import Foundation
import PetalCore
import PetalPersistence

struct CardEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Card")
    static let defaultQuery = CardEntityQuery()
    let id: UUID
    let title: String?

    var displayRepresentation: DisplayRepresentation {
        if let title { return DisplayRepresentation(title: "\(title)") }
        return DisplayRepresentation(title: "Unavailable card")
    }
}

struct CardEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [CardEntity] {
        let query = WidgetCardQuery(repository: try WidgetStore.open())
        return try await query.resolve(ids: identifiers.map { CardID(rawValue: $0) }).map {
            CardEntity(id: $0.id.rawValue, title: $0.title)
        }
    }

    func suggestedEntities() async throws -> [CardEntity] {
        try await WidgetCardQuery(repository: WidgetStore.open()).suggestions().map {
            CardEntity(id: $0.id.rawValue, title: $0.title)
        }
    }
}

enum ThemeOption: String, AppEnum {
    case cream, mint, sakura, sky, paper
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Theme")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .cream: "Cream", .mint: "Mint", .sakura: "Sakura", .sky: "Sky", .paper: "Paper"
    ]
}

enum TypefaceOption: String, AppEnum {
    case standard, rounded, serif
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Typeface")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: "System", .rounded: "Rounded", .serif: "Serif"
    ]
}

enum MaterialOption: String, AppEnum {
    case solid, translucent
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Material")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .solid: "Solid", .translucent: "Translucent"
    ]
}

struct ChecklistWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Checklist"
    static let description = IntentDescription("Choose one card and its appearance.")

    @Parameter(title: "Card") var card: CardEntity?
    @Parameter(title: "Theme", default: .cream) var theme: ThemeOption
    @Parameter(title: "Typeface", default: .standard) var typeface: TypefaceOption
    @Parameter(title: "Material", default: .solid) var material: MaterialOption
}

enum WidgetStore {
    static func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: groupIdentifier()))
    }

    static func cacheDirectory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try groupIdentifier()) else {
            throw RepositoryError.appGroupUnavailable
        }
        return root.appendingPathComponent("Library/Caches/Petal/WidgetSnapshots", isDirectory: true)
    }

    private static func groupIdentifier() throws -> String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PetalAppGroupIdentifier") as? String,
              !group.isEmpty, !group.contains("$(") else { throw RepositoryError.appGroupUnavailable }
        return group
    }
}
