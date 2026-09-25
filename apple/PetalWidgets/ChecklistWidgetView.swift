import SwiftUI
import WidgetKit
import PetalCore
import PetalDesignSystem

enum WidgetRowControl {
    case todo(ToggleTodoIntent), link(URL)
    init(line: WidgetLine, cardID: CardID) {
        self = line.kind == .todo
            ? .todo(ToggleTodoIntent(lineID: line.id, completed: !line.isCompleted))
            : .link(PetalDeepLink.card(cardID).url)
    }
}

struct ChecklistWidgetView: View {
    let entry: ChecklistEntry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Button(intent: OpenCardIntent(cardID: entry.snapshot.cardID)) {
                        HStack(spacing: 6) {
                            Image(systemName: "leaf").accessibilityHidden(true)
                            Text(entry.snapshot.title.isEmpty ? String(localized: "ui.petal.b83a3f", table: "Widgets") : entry.snapshot.title)
                                .font(.headline).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("ui.open_card.32bf59", tableName: "Widgets"))
                    .accessibilityValue(Text(entry.snapshot.title))
                    .disabled(entry.snapshot.cardState == .unavailable)
                    Spacer(minLength: 0)
                    if let badge = entry.snapshot.syncBadge { badgeView(badge) }
                    if entry.snapshot.cardState == .persistenceError {
                        Image(systemName: "exclamationmark.triangle")
                            .accessibilityLabel(Text("ui.unable_to_refresh.e8a1f7", tableName: "Widgets"))
                    }
                    Button(intent: QuickAddIntent(cardID: entry.snapshot.cardID)) {
                        Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("ui.quick_add_to_card.435da3", tableName: "Widgets"))
                    .accessibilityValue(Text(entry.snapshot.title))
                    .disabled(entry.snapshot.cardState != .normal && entry.snapshot.cardState != .empty && entry.snapshot.cardState != .persistenceError)
                }
                if !entry.snapshot.visibleLines.isEmpty {
                    // Fixed widget families cannot fit 5/10 vertical 44pt rows.
                    // Allocate the entire remaining height to non-overlapping full-width targets.
                    let slots = entry.snapshot.visibleLines.count + (entry.snapshot.hiddenCount > 0 ? 1 : 0)
                    let height = max(1, (geometry.size.height - 44) / CGFloat(slots))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entry.snapshot.visibleLines) { line in
                            row(line, height: height)
                        }
                        if entry.snapshot.hiddenCount > 0 {
                            Link(destination: PetalDeepLink.card(entry.snapshot.cardID).url) {
                                Text(String.localizedStringWithFormat(String(localized: "ui.more_items", table: "Widgets"), entry.snapshot.hiddenCount))
                                    .font(.caption).lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("ui.open_card.32bf59", tableName: "Widgets"))
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(stateMessage, tableName: "Widgets")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(.callout, design: PetalTypeface(rawValue: entry.typeface.rawValue)?.design ?? .default))
            .foregroundStyle(renderingMode == .vibrant ? Color.primary : foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            if PetalTheme.usesTransparency(requested: entry.material == .translucent,
                reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased) {
                Rectangle().fill(.regularMaterial).overlay(background.opacity(0.95))
            } else { background }
        }
    }

    @ViewBuilder private func row(_ line: WidgetLine, height: CGFloat) -> some View {
        switch WidgetRowControl(line: line, cardID: entry.snapshot.cardID) {
        case .todo(let intent):
            Toggle(isOn: line.isCompleted, intent: intent) { rowLabel(line, height: height) }
                .toggleStyle(.button).buttonStyle(.plain)
                .accessibilityLabel(Text(line.text))
                .accessibilityValue(Text(line.isCompleted ? "ui.completed.22a970" : "ui.incomplete.75f33c", tableName: "Widgets"))
                .accessibilityHint(Text("ui.toggle_completion.8b0aaf", tableName: "Widgets"))
        case .link(let url):
            Link(destination: url) { rowLabel(line, height: height) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(line.text))
                .accessibilityValue(Text("ui.text_note.6fb03f", tableName: "Widgets"))
                .accessibilityHint(Text("ui.open_card.32bf59", tableName: "Widgets"))
        }
    }

    private func rowLabel(_ line: WidgetLine, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            if line.kind == .todo {
                Image(systemName: line.isCompleted ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
            }
            Text(line.text).strikethrough(line.isCompleted)
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var stateMessage: LocalizedStringKey {
        switch entry.snapshot.cardState {
        case .normal, .empty: "ui.no_items_add_some_in_petal.4016bc"
        case .archived: "ui.this_card_is_archived_edit_the_widget_to_choose_another.9bae01"
        case .trashed: "ui.this_card_is_in_trash_restore_it_in_petal_or_edit_the_w.300709"
        case .unavailable: "ui.choose_a_card_by_editing_this_widget.0fbf4c"
        case .persistenceError: "ui.unable_to_read_this_card_open_petal_to_check_your_local.edd35b"
        }
    }

    private func badgeView(_ badge: WidgetSyncBadge) -> some View {
        let symbol = badge == .syncing ? "arrow.triangle.2.circlepath" : badge == .offline ? "wifi.slash" : "icloud.slash"
        let label: LocalizedStringKey = badge == .syncing ? "ui.syncing.5c8b9e" : badge == .offline ? "ui.offline.a17947" : "ui.sync_failed.abf3e8"
        return Image(systemName: symbol).font(.caption).accessibilityLabel(Text(label, tableName: "Widgets"))
    }

    private var tokens: PetalThemeTokens {
        PetalTheme.tokens(id: ThemeID(rawValue: entry.theme.rawValue) ?? .cream,
            mode: renderingMode == .vibrant ? .vibrant : colorScheme == .dark ? .dark : .light)
    }
    private var foreground: Color { tokens.primary.color }
    private var background: Color {
        if renderingMode == .vibrant { return Color.clear }
        return tokens.surface.color
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
