import SwiftUI
import WidgetKit
import PetalCore

struct ChecklistWidgetView: View {
    let entry: ChecklistEntry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf").accessibilityHidden(true)
                    Text(entry.snapshot.title.isEmpty ? "Petal" : entry.snapshot.title)
                        .font(.headline).lineLimit(1).truncationMode(.tail)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let badge = entry.snapshot.syncBadge { badgeView(badge) }
                    if entry.snapshot.cardState == .persistenceError {
                        Image(systemName: "exclamationmark.triangle")
                            .accessibilityLabel(Text("Unable to refresh", tableName: "Widgets"))
                    }
                }
                if !entry.snapshot.visibleLines.isEmpty {
                    let reserved: CGFloat = entry.snapshot.hiddenCount > 0 ? 47 : 27
                    let height = max(10, (geometry.size.height - reserved) / CGFloat(entry.snapshot.visibleLines.count))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entry.snapshot.visibleLines) { line in
                            HStack(spacing: 8) {
                                if line.kind == .todo {
                                    Image(systemName: line.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .accessibilityHidden(true)
                                }
                                Text(line.text).strikethrough(line.isCompleted)
                                    .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .frame(height: height, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(line.text))
                            .accessibilityValue(line.kind == .text ? Text("") :
                                Text(line.isCompleted ? "Completed" : "Incomplete", tableName: "Widgets"))
                        }
                    }
                    if entry.snapshot.hiddenCount > 0 {
                        Text("\(entry.snapshot.hiddenCount) more", tableName: "Widgets")
                            .font(.caption).lineLimit(1)
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(stateMessage, tableName: "Widgets")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(.callout, design: fontDesign))
            .foregroundStyle(renderingMode == .vibrant ? Color.primary : foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            if entry.material == .translucent {
                Rectangle().fill(.regularMaterial).overlay(background.opacity(0.65))
            } else { background }
        }
    }

    private var stateMessage: LocalizedStringKey {
        switch entry.snapshot.cardState {
        case .normal, .empty: "No items. Add some in Petal."
        case .archived: "This card is archived. Edit the widget to choose another card."
        case .trashed: "This card is in Trash. Restore it in Petal or edit the widget."
        case .unavailable: "Choose a card by editing this widget."
        case .persistenceError: "Unable to read this card. Open Petal to check your local data."
        }
    }

    private func badgeView(_ badge: WidgetSyncBadge) -> some View {
        let symbol = badge == .syncing ? "arrow.triangle.2.circlepath" : badge == .offline ? "wifi.slash" : "icloud.slash"
        let label: LocalizedStringKey = badge == .syncing ? "Syncing" : badge == .offline ? "Offline" : "Sync failed"
        return Image(systemName: symbol).font(.caption).accessibilityLabel(Text(label, tableName: "Widgets"))
    }

    private var fontDesign: Font.Design {
        switch entry.typeface { case .standard: .default; case .rounded: .rounded; case .serif: .serif }
    }
    private var foreground: Color { colorScheme == .dark ? Color(white: 0.96) : Color(white: 0.12) }
    private var background: Color {
        if renderingMode == .vibrant { return Color.clear }
        if colorScheme == .dark {
            switch entry.theme {
            case .cream: return Color(red: 0.20, green: 0.18, blue: 0.14)
            case .mint: return Color(red: 0.12, green: 0.20, blue: 0.17)
            case .sakura: return Color(red: 0.23, green: 0.15, blue: 0.18)
            case .sky: return Color(red: 0.13, green: 0.18, blue: 0.24)
            case .paper: return Color(white: 0.16)
            }
        }
        switch entry.theme {
        case .cream: return Color(red: 0.98, green: 0.95, blue: 0.86)
        case .mint: return Color(red: 0.86, green: 0.95, blue: 0.89)
        case .sakura: return Color(red: 0.99, green: 0.89, blue: 0.91)
        case .sky: return Color(red: 0.87, green: 0.94, blue: 0.99)
        case .paper: return Color(white: 0.96)
        }
    }
}

enum ChecklistWidgetPreviews {
    struct Scenario: Identifiable {
        var id: String { name }
        let name: String
        let entry: ChecklistEntry
        var large = false
        var dark = false
        var vibrant = false
        var largeText = false
    }
    static var scenarios: [Scenario] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gallery = ChecklistTimelineProvider.gallery(now: now, calendar: .current)
        func sample(_ state: WidgetCardState, count: Int = 0, hidden: Int = 0, material: MaterialOption = .solid) -> ChecklistEntry {
            let rows = (0..<count).map { index in
                WidgetLine(id: LineID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!),
                    kind: index == 0 ? .text : .todo,
                    text: index == 0 ? "今天的计划 · A thoughtful plan for a very full day" : "\(index). Make room for a small, meaningful step today",
                    isCompleted: index == count - 1)
            }
            return ChecklistEntry(date: now, snapshot: WidgetSnapshot(cardID: gallery.snapshot.cardID, title: "Today · 今天",
                visibleLines: rows, hiddenCount: hidden, cardState: state, nextRefresh: gallery.snapshot.nextRefresh),
                theme: .cream, typeface: .rounded, material: material)
        }
        return [Scenario(name: "normal-light", entry: gallery),
                Scenario(name: "overflow-medium", entry: sample(.normal, count: 5, hidden: 3)),
                Scenario(name: "overflow-large-dark", entry: sample(.normal, count: 10, hidden: 4), large: true, dark: true),
                Scenario(name: "vibrant", entry: sample(.normal, count: 5), vibrant: true),
                Scenario(name: "translucent-light", entry: sample(.normal, count: 5, material: .translucent)),
                Scenario(name: "translucent-dark", entry: sample(.normal, count: 5, material: .translucent), dark: true),
                Scenario(name: "translucent-vibrant", entry: sample(.normal, count: 5, material: .translucent), vibrant: true),
                Scenario(name: "large-text", entry: sample(.normal, count: 5, hidden: 3), largeText: true),
                Scenario(name: "empty", entry: sample(.empty)),
                Scenario(name: "archived", entry: sample(.archived)),
                Scenario(name: "trashed", entry: sample(.trashed)),
                Scenario(name: "unavailable", entry: sample(.unavailable)),
                Scenario(name: "persistence-error", entry: sample(.persistenceError)),
                Scenario(name: "cached-error", entry: sample(.persistenceError, count: 5, hidden: 2))]
    }
}

struct ChecklistWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(ChecklistWidgetPreviews.scenarios) { scenario in
            ChecklistWidgetView(entry: scenario.entry)
                .environment(\.colorScheme, scenario.dark ? .dark : .light)
                .environment(\.widgetRenderingMode, scenario.vibrant ? .vibrant : .fullColor)
                .environment(\.dynamicTypeSize, scenario.largeText ? .accessibility3 : .large)
                .previewContext(WidgetPreviewContext(family: scenario.large ? .systemLarge : .systemMedium))
                .previewDisplayName(scenario.name)
        }
    }
}
