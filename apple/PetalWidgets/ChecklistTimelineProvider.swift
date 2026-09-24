import Foundation
import WidgetKit
import PetalCore
import PetalPersistence

struct ChecklistEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let theme: ThemeOption
    let typeface: TypefaceOption
    let material: MaterialOption
}

struct ChecklistTimelineProvider: AppIntentTimelineProvider {
    private static let sharedReader = WidgetSnapshotReader(
        cache: WidgetSnapshotCache(directory: { try WidgetStore.cacheDirectory() })
    ) { try WidgetStore.open() }
    let reader: WidgetSnapshotReader

    init(reader: WidgetSnapshotReader = Self.sharedReader) { self.reader = reader }

    func placeholder(in context: Context) -> ChecklistEntry { Self.gallery(now: .now, calendar: .current) }

    func snapshot(for configuration: ChecklistWidgetConfigurationIntent, in context: Context) async -> ChecklistEntry {
        await entry(configuration: configuration, family: context.family, isPreview: context.isPreview, now: .now, calendar: .current)
    }

    func timeline(for configuration: ChecklistWidgetConfigurationIntent, in context: Context) async -> Timeline<ChecklistEntry> {
        let value = await entry(configuration: configuration, family: context.family, isPreview: context.isPreview, now: .now, calendar: .current)
        return timeline(for: value)
    }

    func timeline(for entry: ChecklistEntry) -> Timeline<ChecklistEntry> {
        // A transient local read failure retries in 15 minutes, capped by local midnight.
        let refresh = entry.snapshot.cardState == .persistenceError
            ? min(entry.date.addingTimeInterval(15 * 60), entry.snapshot.nextRefresh)
            : entry.snapshot.nextRefresh
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    func entry(configuration: ChecklistWidgetConfigurationIntent, family: WidgetFamily, isPreview: Bool,
               now: Date, calendar: Calendar) async -> ChecklistEntry {
        if isPreview { return Self.gallery(now: now, calendar: calendar) }
        let snapshot: WidgetSnapshot
        if let card = configuration.card {
            snapshot = await reader.snapshot(cardID: CardID(rawValue: card.id), size: family == .systemLarge ? .large : .medium,
                now: now, calendar: calendar)
        } else {
            snapshot = WidgetSnapshot(cardID: Self.placeholderID, title: "", visibleLines: [], hiddenCount: 0,
                cardState: .unavailable, nextRefresh: calendar.dateInterval(of: .day, for: now)!.end)
        }
        return ChecklistEntry(date: now, snapshot: snapshot, theme: configuration.theme,
            typeface: configuration.typeface, material: configuration.material)
    }

    static let placeholderID = CardID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    /// Static, synthetic samples only: gallery code never opens a store or consumes a selected card.
    static func gallery(now: Date, calendar: Calendar) -> ChecklistEntry {
        let labels = [String(localized: "ui.a_little_space_to_plan.f70d72", table: "Widgets"),
                      String(localized: "ui.make_time_for_what_matters.ab7cd4", table: "Widgets"),
                      String(localized: "ui.one_thing_at_a_time.59d36a", table: "Widgets")]
        let rows = labels.enumerated().map { index, title in
            WidgetLine(id: LineID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!),
                kind: index == 0 ? .text : .todo, text: title, isCompleted: false)
        }
        return ChecklistEntry(date: now, snapshot: WidgetSnapshot(cardID: placeholderID, title: String(localized: "ui.petal.b83a3f", table: "Widgets"), visibleLines: rows,
            hiddenCount: 0, cardState: .normal, nextRefresh: calendar.dateInterval(of: .day, for: now)!.end),
            theme: .cream, typeface: .standard, material: .solid)
    }
}
