import CalopodSnapshot
import SwiftUI

/// Only what belongs to this phone. The reminder times and titles are shown as chosen on the Mac.
struct SettingsScreen: View {
    var info: SettingsInfo
    var snapshot: Snapshot?
    var reminders: Reminders
    var appearance: Appearance
    var filter: CalendarFilter
    var navigation: Navigation
    var selectFeed: (Feed) -> Void = { _ in }
    @Environment(\.openURL) private var openURL

    var body: some View {
        Screen(title: "Settings", subtitle: "This iPhone only", back: BackAction(label: "Back") { navigation.back() }) {
            if reminders.permission != .unavailable { remindersSection }
            SectionLabel(text: "Appearance")
            Card {
                Picker("Appearance", selection: Bindable(appearance).choice) {
                    ForEach(Appearance.Choice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).padding(10)
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            if let snapshot {
                SectionLabel(text: "Calendars shown on this iPhone")
                Card {
                    Button { navigation.push(.calendars) } label: {
                        row("\(filter.summary(in: snapshot))", detail: "Which calendars appear here", chevron: true)
                    }
                    .buttonStyle(.plain)
                }
                .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            }
            if let snapshot, let feed = snapshot.feed { feedSection(feed, all: snapshot.feeds) }
            SectionLabel(text: "iCloud")
            Card {
                row("iCloud", value: icloudText, tone: info.icloud == .signedIn ? Theme.good : Theme.bad)
                Divider().overlay(Theme.line)
                row("Last update from your Mac", value: info.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "None yet")
                Divider().overlay(Theme.line)
                note("Turn on iPhone sync in the Calopod app on your Mac.")
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            SectionLabel(text: "About")
            Card {
                row("Version", value: AppInfo.version())
                Divider().overlay(Theme.line)
                note("Your calendar data lives in your own iCloud. Calopod never sends it anywhere else.")
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            ReadOnlyFoot(text: "Working hours, sync, colors and answers to invitations all stay on your Mac.")
        }
    }

    private func feedSection(_ current: Feed, all feeds: [Feed]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Feed")
            Card {
                ForEach(feeds) { feed in
                    Button { selectFeed(feed) } label: {
                        HStack {
                            rowLabel(feed.name, detail: feedDetail(feed))
                            Spacer(minLength: 8)
                            if feed.id == current.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(feed.id == current.id ? .isSelected : [])
                    Divider().overlay(Theme.line)
                }
                note(current.isShared
                    ? "Shared with you. You can only read it, and whoever shared it can stop at any time."
                    : "From your own iCloud.")
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
    }

    private func feedDetail(_ feed: Feed) -> String {
        let source = feed.isShared ? "Shared with you" : "Your iCloud"
        return feed.level == .busy ? "\(source), busy time only" : source
    }

    private var icloudText: String {
        switch info.icloud {
        case .signedIn: "Signed in"
        case .signedOut: "Not signed in"
        case .unreachable: "Can't reach iCloud"
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Reminders on this iPhone")
            Card {
                switch reminders.permission {
                case .allowed:
                    Toggle(isOn: Bindable(reminders).isOn) { rowLabel("Meeting reminders", detail: "Shown on this iPhone only") }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider().overlay(Theme.line)
                    row("Notifications", value: "Allowed", tone: Theme.good)
                    Divider().overlay(Theme.line)
                    settingsLink("Change in iOS Settings")
                case .denied:
                    row("Notifications", value: "Off", tone: Theme.caution)
                    Divider().overlay(Theme.line)
                    note("Reminders can't appear until notifications are allowed for Calopod.")
                    settingsLink(nil)
                default:
                    note("To show reminders before meetings, Calopod needs your permission to send notifications.")
                    Button("Allow reminders") { Task { await reminders.requestPermission() } }
                        .font(Theme.Fonts.bodyStrong).padding(.horizontal, 14).padding(.bottom, 12)
                }
                Divider().overlay(Theme.line)
                row("Lead times", value: info.leadTimes, detail: "Set on your Mac")
                Divider().overlay(Theme.line)
                row("Titles in reminders", value: info.titles, detail: "Set on your Mac")
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
    }

    private func settingsLink(_ text: String?) -> some View {
        HStack {
            if let text { Text(text).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary) }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(Theme.Fonts.bodyStrong)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func rowLabel(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.Fonts.bodyStrong)
            if let detail { Text(detail).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary) }
        }
    }

    private func row(_ title: String, value: String? = nil, detail: String? = nil, tone: Color = Theme.secondary, chevron: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            rowLabel(title, detail: value == nil ? detail : nil)
            Spacer(minLength: 8)
            if let value {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value).font(Theme.Fonts.body).foregroundStyle(tone)
                    if let detail { Text(detail).font(.caption2).foregroundStyle(Theme.faint) }
                }
            }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Show or hide each calendar the Mac sent events for. It only changes this phone.
struct CalendarsScreen: View {
    var snapshot: Snapshot?
    var filter: CalendarFilter
    var navigation: Navigation

    var body: some View {
        let calendars = snapshot.map(CalendarFilter.listed) ?? []
        Screen(title: "Calendars", subtitle: "Shown on this iPhone", back: BackAction(label: "Back") { navigation.back() }) {
            Card {
                if calendars.isEmpty {
                    Text("No calendars chosen on your Mac yet.").font(Theme.Fonts.body).padding(16)
                }
                ForEach(Array(calendars.enumerated()), id: \.offset) { index, calendar in
                    Toggle(isOn: Binding(get: { filter.isShown(calendar.id) }, set: { filter.setShown($0, for: calendar.id) })) {
                        Label { Text(calendar.name) } icon: {
                            Circle().fill(Theme.calendarColor(calendar)).frame(width: 10, height: 10)
                        }
                    }
                    .font(Theme.Fonts.body).padding(.horizontal, 14).padding(.vertical, 8)
                    if index < calendars.count - 1 { Divider().overlay(Theme.line) }
                }
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            Text("Hiding a calendar only changes this phone. The free and busy totals count all of them.")
                .font(Theme.Fonts.secondary).foregroundStyle(Theme.faint).padding(.horizontal, 4)
        }
    }
}

struct HelpScreen: View {
    var navigation: Navigation

    private let steps = ["Open Calopod on your Mac", "Go to Settings, then iPhone", "Turn on Share with iPhone"]
    private let topics = [
        ("This app only shows things", "Your Mac makes every change. Answer invitations and edit calendars there."),
        ("Nothing showing, or out of date?", "Open Status. It tells you when the Mac last updated and what failed."),
        ("Reminders", "Allow notifications for Calopod in iOS Settings. Lead times and hidden titles are chosen on your Mac."),
        ("Where your data goes", "Only through your own iCloud."),
    ]

    var body: some View {
        Screen(title: "Help", subtitle: "Set up Calopod for iPhone", back: BackAction(label: "Back") { navigation.back() }) {
            SectionLabel(text: "Turn it on")
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(Theme.Fonts.caption).frame(width: 24, height: 24)
                        .background(Theme.accent, in: Circle()).foregroundStyle(Theme.onAccent)
                    Text(step).font(Theme.Fonts.body)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            SectionLabel(text: "Good to know")
            Card {
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.0).font(Theme.Fonts.bodyStrong)
                        Text(topic.1).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    if index < topics.count - 1 { Divider().overlay(Theme.line) }
                }
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
    }
}

struct AboutScreen: View {
    var navigation: Navigation

    var body: some View {
        Screen(title: "About", subtitle: "Calopod for iPhone", back: BackAction(label: "Back") { navigation.back() }) {
            Card {
                HStack {
                    Text("Version").font(Theme.Fonts.bodyStrong)
                    Spacer()
                    Text(AppInfo.version()).font(Theme.Fonts.body).foregroundStyle(Theme.secondary)
                }
                .padding(14)
                Divider().overlay(Theme.line)
                Text("Calopod for iPhone is a read-only companion. Your Mac publishes what it shows here to your own iCloud, and Calopod never sends it anywhere else. Nothing on this phone changes a calendar.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary).padding(14)
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
    }
}
