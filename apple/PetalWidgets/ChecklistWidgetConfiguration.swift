import AppIntents
import Foundation
import PetalCore
import PetalPersistence

struct CardEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("ui.card.be3702", table: "Widgets"))
    static let defaultQuery = CardEntityQuery()
    let id: UUID
    let title: String?

    var displayRepresentation: DisplayRepresentation {
        if let title { return DisplayRepresentation(title: "\(title)") }
        return DisplayRepresentation(title: LocalizedStringResource("ui.unavailable_card.bb3b4a", table: "Widgets"))
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
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("ui.theme.efb52e", table: "Widgets"))
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .cream: DisplayRepresentation(title: LocalizedStringResource("ui.cream.d5398b", table: "Widgets")), .mint: DisplayRepresentation(title: LocalizedStringResource("ui.mint.ced97c", table: "Widgets")), .sakura: DisplayRepresentation(title: LocalizedStringResource("ui.sakura.95c0d6", table: "Widgets")), .sky: DisplayRepresentation(title: LocalizedStringResource("ui.sky.b72804", table: "Widgets")), .paper: DisplayRepresentation(title: LocalizedStringResource("ui.paper.35045e", table: "Widgets"))
    ]
}

enum TypefaceOption: String, AppEnum {
    case standard, rounded, serif
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("ui.typeface.3a8c10", table: "Widgets"))
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: DisplayRepresentation(title: LocalizedStringResource("ui.system.6725e7", table: "Widgets")), .rounded: DisplayRepresentation(title: LocalizedStringResource("ui.rounded.0a62cd", table: "Widgets")), .serif: DisplayRepresentation(title: LocalizedStringResource("ui.serif.1b5e74", table: "Widgets"))
    ]
}

enum MaterialOption: String, AppEnum {
    case solid, translucent
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("ui.material.616cb2", table: "Widgets"))
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .solid: DisplayRepresentation(title: LocalizedStringResource("ui.solid.b8b311", table: "Widgets")), .translucent: DisplayRepresentation(title: LocalizedStringResource("ui.translucent.fa5668", table: "Widgets"))
    ]
}

struct ChecklistWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("ui.checklist.734603", table: "Widgets")
    static let description = IntentDescription(LocalizedStringResource("ui.choose_one_card_and_its_appearance.d346f6", table: "Widgets"))

    @Parameter(title: LocalizedStringResource("ui.card.be3702", table: "Widgets")) var card: CardEntity?
    @Parameter(title: LocalizedStringResource("ui.theme.efb52e", table: "Widgets"), default: .cream) var theme: ThemeOption
    @Parameter(title: LocalizedStringResource("ui.typeface.3a8c10", table: "Widgets"), default: .standard) var typeface: TypefaceOption
    @Parameter(title: LocalizedStringResource("ui.material.616cb2", table: "Widgets"), default: .solid) var material: MaterialOption
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
