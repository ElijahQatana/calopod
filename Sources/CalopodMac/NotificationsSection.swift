import CalopodCommands
import CalopodStore
import SwiftUI

/// Meeting reminders in Settings: a master switch, a first and a final reminder with their own times,
/// and whether notifications show the event title. The daily Inbox digest sits below them.
struct NotificationsSection: View {
    let model: NotificationSettingsModel
    let workingHours: WorkingHours
    let permission: NotificationPermissionState?

    var body: some View {
        CardSection("Notifications", footnote: footnote) {
            CardRow("Meeting reminders") { toggle("Meeting reminders", model.settings.enabled) { value in model.apply { try $0.changing(enabled: value) } } }
            reminderRow(
                "First reminder", on: model.settings.firstEnabled, minutes: model.settings.firstMinutes, range: model.firstRange,
                setOn: { value in model.apply { try $0.changing(firstEnabled: value) } },
                setMinutes: { value in model.apply { try $0.changing(firstMinutes: value) } })
            reminderRow(
                "Final reminder", on: model.settings.finalEnabled, minutes: model.settings.finalMinutes, range: model.finalRange,
                setOn: { value in model.apply { try $0.changing(finalEnabled: value) } },
                setMinutes: { value in model.apply { try $0.changing(finalMinutes: value) } })
            CardRow("Hide event titles in notifications") {
                toggle("Hide event titles in notifications", model.settings.hideTitles) { value in model.apply { try $0.changing(hideTitles: value) } }
                    .disabled(!model.settings.enabled)
            }
            CardRow("Daily Inbox digest") { toggle("Daily Inbox digest", model.digest.enabled) { value in model.applyDigest(enabled: value) } }
            if model.digest.enabled {
                CardRow("Digest time") {
                    DatePicker(
                        "Digest time",
                        selection: Binding(
                            get: { WorkingHoursSection.date(model.digest.minute(workingHours: workingHours)) },
                            set: { newValue in MainActor.assumeIsolated { model.applyDigest(minute: WorkingHoursSection.minute(newValue)) } }),
                        displayedComponents: .hourAndMinute
                    ).labelsHidden()
                }
                if permission == .denied || permission == .notDetermined {
                    CardRow { Banner(kind: .caution, text: "Notifications are not allowed for Calopod, so the digest will not appear. Allow them under Permissions.") }
                }
            }
            if let notice = model.notice { CardRow { Banner(kind: .caution, text: notice) } }
        }
        .onAppear { model.reload() }
    }

    private var footnote: String {
        "Times are minutes before the start, from 1 to 120. The final reminder comes after the first, so it needs fewer minutes. "
            + "With titles hidden a notification only says a meeting is starting. "
            + "macOS keeps the reminders scheduled, so they still arrive when Calopod is closed. "
            + "The digest is one notification a day with counts of what is waiting in the Inbox, never titles, and is skipped when nothing is. "
            + "It comes at the start of your working day unless you pick a time. "
            + "The command line can change these with calopod notifications."
    }

    // The setters go through plain closures: Xcode 16.4 crashes building a thunk for the isolated function value.
    private func toggle(_ title: String, _ value: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { newValue in MainActor.assumeIsolated { set(newValue) } })).labelsHidden().toggleStyle(.switch)
    }

    private func reminderRow(
        _ title: String, on: Bool, minutes: Int, range: ClosedRange<Int>,
        setOn: @escaping @MainActor @Sendable (Bool) -> Void, setMinutes: @escaping @MainActor @Sendable (Int) -> Void
    ) -> some View {
        CardRow(title) {
            HStack(spacing: 12) {
                if on && model.settings.enabled {
                    Text("\(ReminderPlanner.minutesText(minutes)) before").font(Theme.Fonts.body).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper(
                        "\(title) minutes", value: Binding(get: { minutes }, set: { newValue in MainActor.assumeIsolated { setMinutes(newValue) } }),
                        in: range.contains(minutes) ? range : minutes...minutes
                    ).labelsHidden()
                }
                toggle(title, on, set: setOn)
            }
        }
        .disabled(!model.settings.enabled)
    }
}
