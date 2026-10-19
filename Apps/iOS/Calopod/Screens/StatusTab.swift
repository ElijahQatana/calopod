import CalopodSnapshot
import SwiftUI

struct StatusTab: View {
    var context: SnapshotContext
    var reminders: Reminders

    var body: some View {
        let report = StatusReport(status: context.snapshot.status, calendars: context.snapshot.calendars)
        Screen(title: "Status", subtitle: "Reported by your Mac") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Card {
                HStack(spacing: 12) {
                    Image(systemName: report.hasFailure ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.title2).foregroundStyle(report.hasFailure ? Theme.bad : Theme.good)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.hasFailure ? "Last sync didn't finish" : "Syncing normally").font(Theme.Fonts.heading)
                        Text(report.lastSyncAt.map { "Last sync \($0.formatted(timeFormat))" } ?? "No sync yet")
                            .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            if !report.issues.isEmpty {
                SectionLabel(text: "Needs attention")
                Card {
                    ForEach(Array(report.issues.enumerated()), id: \.offset) { index, issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.kind == .failed ? "xmark.circle" : "clock")
                                .foregroundStyle(color(issue.kind))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.message(for: issue)).font(Theme.Fonts.body)
                                if let since = issue.since {
                                    Text("Since \(since.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .accessibilityElement(children: .combine)
                        if index < report.issues.count - 1 { Divider().overlay(Theme.line) }
                    }
                }
                .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            }
            if reminders.permission != .unavailable {
                SectionLabel(text: "Meeting reminders")
                ReminderCard(reminders: reminders, settings: context.snapshot.reminders)
            }
            SectionLabel(text: "Calendars")
            Card {
                ForEach(Array(report.rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Label { Text(row.calendar.name) } icon: {
                            Circle().fill(Theme.calendarColor(row.calendar.colorIndex)).frame(width: 10, height: 10)
                        }
                        Spacer()
                        if let issue = row.issue {
                            Text(label(issue.kind)).font(Theme.Fonts.secondary).foregroundStyle(color(issue.kind))
                        }
                    }
                    .font(Theme.Fonts.body).padding(14)
                    .accessibilityElement(children: .combine)
                    if index < report.rows.count - 1 { Divider().overlay(Theme.line) }
                }
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            Card {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up on your Mac").font(Theme.Fonts.bodyStrong)
                    Text("Arms, Main and Busy calendars, colors and what syncs are all chosen in Calopod on your Mac.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                }
                .padding(14)
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            ReadOnlyFoot(text: "Synced through your private iCloud.")
        }
    }

    private func color(_ kind: SyncIssueKind) -> Color { kind == .failed ? Theme.bad : Theme.caution }

    private func label(_ kind: SyncIssueKind) -> String {
        switch kind {
        case .failed: "Failed"
        case .partial: "Partial"
        case .stale: "Behind"
        }
    }
}

/// The phone's permission and its one switch for meeting reminders. The times come from the Mac.
private struct ReminderCard: View {
    @Bindable var reminders: Reminders
    var settings: ReminderSettings?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                switch reminders.permission {
                case .allowed:
                    Toggle("Remind me on this phone", isOn: $reminders.isOn).font(Theme.Fonts.bodyStrong)
                    Text(ReminderPlan.summary(settings)).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    Text("Turn this off if your Mac already reminds you and you don't want both.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                case .denied:
                    Text("Reminders are blocked").font(Theme.Fonts.bodyStrong)
                    Text("Notifications are off for Calopod. Allow them in Settings to get reminders on this phone.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(Theme.Fonts.bodyStrong)
                default:
                    Text("Get a reminder before each meeting").font(Theme.Fonts.bodyStrong)
                    Text("Calopod sets reminders on this phone from the events your Mac shares, at the times chosen on your Mac. To show them it needs your permission to send notifications.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    Button("Allow reminders") { Task { await reminders.requestPermission() } }
                        .font(Theme.Fonts.bodyStrong)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }
}
