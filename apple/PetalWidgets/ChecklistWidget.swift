import SwiftUI
import WidgetKit

struct ChecklistWidget: Widget {
    static let kind = "PetalChecklist"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ChecklistWidgetConfigurationIntent.self,
            provider: ChecklistTimelineProvider()) { entry in
                ChecklistWidgetView(entry: entry)
            }
            .configurationDisplayName("Petal Checklist")
            .description("One card, always close at hand.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
