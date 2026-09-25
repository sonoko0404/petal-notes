import SwiftUI
import PetalCore
import PetalNotifications
import AppKit

@MainActor
struct NotificationSettingsOpener {
    var openURL: @MainActor (URL) -> Bool
    static let system = NotificationSettingsOpener(openURL: { NSWorkspace.shared.open($0) })
    func open() -> Bool {
        openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}

struct ReminderEditorView: View {
    let line: CardLine
    let model: CardEditorModel
    @State private var daily = false
    @State private var enabled = true
    @State private var date = Date.now.addingTimeInterval(3600)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ui.reminder.31757b").font(.headline)
            Text("ui.notification_permission").font(.caption)
            Toggle("ui.enable_reminder.1be5b1", isOn: $enabled)
            Toggle("ui.repeat_daily.fa53cc", isOn: $daily)
            if daily {
                Text("ui.completing_early_may_still_allow_today_s_reminder_futur.3aa89b")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DatePicker("ui.reminder_time.80381e", selection: $date, displayedComponents: daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                .accessibilityIdentifier("reminder.time")
            if model.reminderErrors.contains(line.id) { Text("ui.unable_to_save_reminder_your_input_is_kept.45d119").foregroundStyle(.red) }
            if let state = model.reminderStates[line.id] {
                switch state {
                case .permissionDenied:
                    Text("ui.reminder_saved_notifications_are_disabled_in_system_set.b45158")
                    Button("ui.open_notification_settings.7fd93e") { model.openNotificationSettings(lineID: line.id) }
                        .accessibilityIdentifier("reminder.openSettings")
                        .keyboardShortcut(",", modifiers: [.command])
                case .permissionRequired: Text("ui.reminder_saved_notification_permission_is_needed.689dd2")
                case .schedulingFailed: Text("ui.reminder_saved_scheduling_failed_save_again_to_retry.a3cbad").foregroundStyle(.red)
                case .scheduled: Text("ui.reminder_saved.6d29b5")
                }
            }
            if model.settingsOpenErrors.contains(line.id) {
                Text("ui.unable_to_open_system_settings_open_notifications_in_sy.b7638d").foregroundStyle(.red)
            }
            HStack {
                Button("ui.close.7d9eb7") { dismiss() }
                Spacer()
                Button("ui.remove_reminder.0fb9ab") {
                    model.editReminder(lineID: line.id, reminder: nil)
                    Task { _ = await model.saveReminder(lineID: line.id) }
                }
                Button("ui.save_reminder.88f5cf") {
                    updateDraft()
                    Task { _ = await model.saveReminder(lineID: line.id) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("reminder.save")
            }
        }
        .padding(24).frame(width: 420)
        .disabled(model.isSavingReminder)
        .interactiveDismissDisabled(model.isSavingReminder)
        .task { await model.refreshReminderAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshReminderAuthorization() }
        }
        .onAppear {
            let reminder = model.reminderDrafts[line.id]?.value ?? line.reminder
            if let reminder {
                enabled = reminder.isEnabled
                switch reminder.rule {
                case .oneTime(let instant): date = instant
                case .daily(let minute, _):
                    daily = true
                    date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? date
                }
            }
        }
        .onChange(of: enabled) { _, _ in updateDraft() }
        .onChange(of: daily) { _, _ in updateDraft() }
        .onChange(of: date) { _, _ in updateDraft() }
    }
    private func updateDraft() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let rule: ReminderRule = daily
            ? .daily(localMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0), timeZoneIdentifier: TimeZone.current.identifier)
            : .oneTime(date)
        model.editReminder(lineID: line.id, reminder: Reminder(rule: rule, isEnabled: enabled))
    }
}
