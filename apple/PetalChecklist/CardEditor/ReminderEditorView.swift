import SwiftUI
import PetalCore
import PetalNotifications

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
            DatePicker("Reminder Time", selection: $date, displayedComponents: daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                .accessibilityIdentifier("reminder.time")
            if model.reminderError { Text("Unable to save reminder. Your input is kept.").foregroundStyle(.red) }
            if let state = model.reminderState {
                switch state {
                case .permissionDenied: Text("Reminder saved. Notifications are disabled in System Settings.")
                case .permissionRequired: Text("Reminder saved. Notification permission is needed.")
                case .schedulingFailed: Text("Reminder saved. Scheduling failed. Save again to retry.").foregroundStyle(.red)
                case .scheduled: Text("Reminder saved.")
                }
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
