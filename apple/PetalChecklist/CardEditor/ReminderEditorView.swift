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
            Text("Reminder").font(.headline)
            Toggle("Enable Reminder", isOn: $enabled)
            Toggle("Repeat Daily", isOn: $daily)
            if daily {
                Text("Completing early may still allow today's reminder. Future daily reminders continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DatePicker("Reminder Time", selection: $date, displayedComponents: daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                .accessibilityIdentifier("reminder.time")
            if model.reminderErrors.contains(line.id) { Text("Unable to save reminder. Your input is kept.").foregroundStyle(.red) }
            if let state = model.reminderStates[line.id] {
                switch state {
                case .permissionDenied:
                    Text("Reminder saved. Notifications are disabled in System Settings.")
                    Button("Open Notification Settings") { model.openNotificationSettings(lineID: line.id) }
                        .accessibilityIdentifier("reminder.openSettings")
                        .keyboardShortcut(",", modifiers: [.command])
                case .permissionRequired: Text("Reminder saved. Notification permission is needed.")
                case .schedulingFailed: Text("Reminder saved. Scheduling failed. Save again to retry.").foregroundStyle(.red)
                case .scheduled: Text("Reminder saved.")
                }
            }
            if model.settingsOpenErrors.contains(line.id) {
                Text("Unable to open System Settings. Open Notifications in System Settings manually.").foregroundStyle(.red)
            }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Remove Reminder") {
                    model.editReminder(lineID: line.id, reminder: nil)
                    Task { _ = await model.saveReminder(lineID: line.id) }
                }
                Button("Save Reminder") {
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
