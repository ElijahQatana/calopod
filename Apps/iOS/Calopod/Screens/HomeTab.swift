import CalopodSnapshot
import SwiftUI

/// The phone's overview: what needs you, what is next today and how much time is free, from the Mac. It only opens other tabs. Nothing here changes anything.
struct HomeTab: View {
    var context: SnapshotContext
    var filter: CalendarFilter
    var navigation: Navigation

    var body: some View {
        let summary = HomeSummary(context: context, hidden: filter.hidden)
        Screen(title: "Home", subtitle: "\(context.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(context.fromMac)") {
            VStack(alignment: .leading, spacing: 12) {
                if summary.sync == .didNotFinish { SyncProblemLine { navigation.show(.status) } }
                if context.isStale {
                    OldDataNote(lastUpdate: context.snapshot.publishedAt, now: context.now) { navigation.show(.status) }
                }
                if let glance = summary.glance, glance.text() != nil { GlanceLine(glance: glance) }
                Group {
                    HomeSection("Needs you", link: "Open Inbox") { navigation.openInbox(.all) } content: {
                        needsYou(summary)
                    }
                    HomeSection("Next up today", link: "Open Calendar") { navigation.openSchedule() } content: {
                        NextUp(summary: summary) { navigation.openSchedule() }
                    }
                    if !context.isStale {
                        HomeSection("Availability today", link: "Open Availability") { navigation.openAvailability() } content: {
                            AvailabilityTodayTile(figures: summary.availability) { navigation.openAvailability() }
                        }
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

private struct SyncProblemLine: View {
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                Text("**Last sync didn't finish.** Open Status for details.").font(Theme.Fonts.secondary).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Status")
    }
}

private struct GlanceLine: View {
    var glance: HomeSummary.Glance

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock").foregroundStyle(Theme.good)
            line.font(Theme.Fonts.secondary).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var line: Text {
        let rest = glance.meetingsText.map { Text($0).foregroundStyle(Theme.secondary) }
        guard let free = glance.freeText() else { return rest ?? Text("") }
        let lead = Text(free).fontWeight(.semibold).foregroundStyle(Theme.text)
        guard let rest else { return lead }
        return lead + Text(" · ").foregroundStyle(Theme.secondary) + rest
    }
}

private struct OldDataNote: View {
    var lastUpdate: Date
    var now: Date
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz").foregroundStyle(Theme.caution)
                Text("\(Age.lastUpdated(lastUpdate, now: now)). Your Mac may be asleep or offline.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Status")
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
                Text(chip).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1).fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Theme.accentSoft, in: Capsule())
            }
            if let join = next.event.joinLink { JoinPill(url: join) }
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
