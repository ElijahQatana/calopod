import CalopodSnapshot
import SwiftUI

/// The phone's overview: sync health, what needs you, what is next today and the calendars
/// from the Mac. It only opens other tabs. Nothing here changes anything.
struct HomeTab: View {
    var context: SnapshotContext
    var filter: CalendarFilter
    var navigation: Navigation

    var body: some View {
        let summary = HomeSummary(context: context, hidden: filter.hidden)
        Screen(title: "Home", subtitle: "\(context.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(context.fromMac)") {
            VStack(alignment: .leading, spacing: 12) {
                SyncCard(summary: summary) { navigation.show(.status) }
                if context.isStale { OldDataNote(lastUpdate: context.snapshot.publishedAt, now: context.now) }
                Group {
                    HomeSection("Needs you", link: "Open Inbox") { navigation.openInbox(.all) } content: {
                        needsYou(summary)
                    }
                    HomeSection("Next up today", link: "Open Calendar") { navigation.show(.calendar) } content: {
                        NextUp(summary: summary) { navigation.show(.calendar) }
                    }
                    if !context.isStale {
                        HomeSection("Availability today", link: "Open Availability") { navigation.openAvailability() } content: {
                            AvailabilityTodayTile(figures: summary.availability) { navigation.openAvailability() }
                        }
                    }
                    HomeSection("Calendars", link: "Open Status") { navigation.show(.status) } content: {
                        CalendarsCard(summary: summary) { navigation.show(.status) }
                    }
                }
                .opacity(context.isStale ? 0.6 : 1)
            }
        }
    }

    private func needsYou(_ summary: HomeSummary) -> some View {
        HStack(spacing: 8) {
            NeedsTile(count: summary.invitations, label: "Invitations waiting", highlight: true) { navigation.openInbox(.needsRSVP) }
            NeedsTile(count: summary.overlaps, label: "Overlapping events", highlight: false) { navigation.openInbox(.conflicts) }
            NeedsTile(count: summary.changes, label: "Changed since you looked", highlight: false) { navigation.openInbox(.changes) }
        }
    }
}

/// A heading with an optional link that opens the matching tab.
private struct HomeSection<Content: View>: View {
    var title: String
    var link: String?
    var open: () -> Void
    var content: Content

    init(_ title: String, link: String? = nil, open: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.title = title
        self.link = link
        self.open = open
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                if let link {
                    Button(link, action: open).font(Theme.Fonts.caption).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                }
            }
            content
        }
    }
}

private struct SyncCard: View {
    var summary: HomeSummary
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: summary.sync == .inSync ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.title3).foregroundStyle(summary.sync == .inSync ? Theme.good : Theme.caution)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Theme.Fonts.bodyStrong)
                        Text(summary.lastSync.map { "Last synced \($0.formatted(timeFormat))" } ?? "No sync yet")
                            .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch summary.sync {
        case .inSync: "Everything is in sync"
        case .didNotFinish: "Last sync didn't finish"
        case .behind: "Not up to date"
        }
    }
}

private struct OldDataNote: View {
    var lastUpdate: Date
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz").foregroundStyle(Theme.caution)
            Text("\(Age.lastUpdated(lastUpdate, now: now)). Your Mac may be asleep or offline.")
                .font(Theme.Fonts.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct NeedsTile: View {
    var count: Int
    var label: String
    var highlight: Bool
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)").font(Theme.Fonts.title).foregroundStyle(highlight && count > 0 ? Theme.accent : Theme.text)
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Inbox")
    }
}

private struct NextUp: View {
    var summary: HomeSummary
    var openCalendar: () -> Void

    var body: some View {
        Card {
            if !summary.hasCalendars {
                note("No calendar chosen on your Mac", "Choose calendars to share in Calopod on your Mac, under Settings, then iPhone.")
            } else if summary.next.isEmpty {
                note("Nothing more today", nil)
            }
            ForEach(Array(summary.next.enumerated()), id: \.offset) { index, next in
                row(next)
                if index < summary.next.count - 1 || summary.moreToday > 0 { Divider().overlay(Theme.line) }
            }
            if summary.moreToday > 0 {
                Button(action: openCalendar) {
                    Text("and \(summary.moreToday) more").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }

    private func note(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Fonts.bodyStrong)
            if let detail { Text(detail).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ next: HomeSummary.Next) -> some View {
        HStack(spacing: 10) {
            Text(next.event.startsAt.formatted(timeFormat)).font(Theme.Fonts.bodyStrong).monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(next.event.displayTitle).font(Theme.Fonts.bodyStrong).lineLimit(1)
                Text(DurationText.text(next.event.endsAt.timeIntervalSince(next.event.startsAt)))
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            if let chip = next.chip {
                Text(chip).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Theme.accentSoft, in: Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Today's free, busy and outside time as the Mac published it. An older Mac has the busy time only.
struct AvailabilityTodayTile: View {
    var figures: AvailabilityFigures?
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Card {
                if let figures {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 24) {
                            if let free = figures.freeTime { total(DurationText.text(free), "Free", Theme.good) }
                            total(DurationText.text(figures.busyTime), "Busy", Theme.text)
                            Spacer(minLength: 0)
                        }
                        Text(figures.hoursLine()).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        if figures.outsideTime > 0 {
                            Text("Outside working hours \(DurationText.text(figures.outsideTime))")
                                .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Nothing has been published for today.").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Availability")
    }

    private func total(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.Fonts.heading).monospacedDigit().foregroundStyle(color)
            Text(label).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
        }
    }
}

private struct CalendarsCard: View {
    var summary: HomeSummary
    var openStatus: () -> Void

    var body: some View {
        Card {
            if summary.calendars.isEmpty {
                Text("No calendars shared yet.").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary).padding(14)
            }
            ForEach(Array(summary.calendars.enumerated()), id: \.offset) { index, row in
                HStack {
                    Label { Text(row.calendar.name) } icon: {
                        Circle().fill(Theme.calendarColor(row.calendar)).frame(width: 10, height: 10)
                    }
                    Spacer()
                    Text(row.issue?.kind.label ?? "Up to date").font(Theme.Fonts.secondary)
                        .foregroundStyle(row.issue?.kind.color ?? Theme.secondary)
                }
                .font(Theme.Fonts.body).padding(.horizontal, 14).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if index < summary.calendars.count - 1 || summary.moreCalendars > 0 { Divider().overlay(Theme.line) }
            }
            if summary.moreCalendars > 0 {
                Button(action: openStatus) {
                    Text("and \(summary.moreCalendars) more").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }
}
