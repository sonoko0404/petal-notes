import SwiftUI
import WidgetKit

struct ChecklistWidget: Widget {
    static let kind = "PetalChecklist"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ChecklistWidgetConfigurationIntent.self,
            provider: ChecklistTimelineProvider()) { entry in
                ChecklistWidgetView(entry: entry)
            }
            .configurationDisplayName(String(localized: "ui.petal_checklist.d92314", table: "Widgets"))
            .description(String(localized: "ui.one_card_always_close_at_hand.8585f6", table: "Widgets"))
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
