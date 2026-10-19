import CalopodSnapshot
import SwiftUI

/// Busy time for the next two weeks. The feed has no event titles for a day, so this shows
/// when you are busy, not what with.
struct CalendarTab: View {
    var context: SnapshotContext
    @State private var selected: String?

    var body: some View {
        let days = DaySchedule.schedules(from: context.snapshot.availability)
        let day = days.first { $0.day == selected } ?? days.first { $0.interval.contains(context.now) } ?? days.first
        Screen(title: "Calendar", subtitle: "Busy time \(context.fromMac)") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                if let day {
                    DayStrip(days: days, selected: day.day) { selected = $0 }
                    DaySummary(day: day)
                    SectionLabel(text: "Busy")
                    BusyList(day: day)
                } else {
                    Card { Text("No busy time has been published.").font(Theme.Fonts.body).padding(16) }
                }
                ReadOnlyFoot(text: "Based on your Mac's last update at \(context.snapshot.publishedAt.formatted(timeFormat)).")
            }
            .opacity(context.isStale ? 0.6 : 1)
        }
    }
}

private func format(_ date: Date, in timeZone: TimeZone) -> String {
    date.formatted(Date.FormatStyle(timeZone: timeZone).hour().minute())
}

private struct DayStrip: View {
    var days: [DaySchedule]
    var selected: String
    var select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(days, id: \.day) { day in
                    let on = day.day == selected
                    Button { select(day.day) } label: {
                        VStack(spacing: 4) {
                            Text(day.interval.start.formatted(Date.FormatStyle(timeZone: day.timeZone).weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                            Text(day.interval.start.formatted(Date.FormatStyle(timeZone: day.timeZone).day()))
                                .font(Theme.Fonts.heading)
                            Circle().fill(on ? Theme.onAccent : Theme.accent).frame(width: 5, height: 5)
                                .opacity(day.busy.isEmpty ? 0 : 1)
                        }
                        .frame(width: 46, height: 72)
                        .foregroundStyle(on ? Theme.onAccent : Theme.text)
                        .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.text.opacity(on ? 0 : 0.06), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.interval.start.formatted(Date.FormatStyle(timeZone: day.timeZone).weekday(.wide).day().month(.wide)))
                    .accessibilityValue(day.busy.isEmpty ? "Free" : "Busy")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
        }
    }
}

private struct DaySummary: View {
    var day: DaySchedule

    var body: some View {
        HStack(spacing: 12) {
            tile(DurationText.text(day.freeTime), "Free", color: Theme.good)
            tile(DurationText.text(day.busyTime), "Busy", color: Theme.text)
        }
    }

    private func tile(_ value: String, _ label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Fonts.heading).foregroundStyle(color)
            Text(label).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

private struct BusyList: View {
    var day: DaySchedule

    var body: some View {
        Card {
            if day.busy.isEmpty {
                Text("Nothing busy on this day.").font(Theme.Fonts.body).padding(16)
            }
            ForEach(Array(day.busy.enumerated()), id: \.offset) { index, block in
                HStack {
                    Image(systemName: "clock").foregroundStyle(Theme.accent)
                    Text(text(block)).font(Theme.Fonts.bodyStrong).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(14)
                .accessibilityElement(children: .combine)
                if index < day.busy.count - 1 { Divider().overlay(Theme.line) }
            }
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }

    private func text(_ block: BusyBlock) -> String {
        let start = block.continuesFromYesterday ? "Yesterday" : format(block.interval.start, in: day.timeZone)
        let end = block.continuesTomorrow ? "tomorrow" : format(block.interval.end, in: day.timeZone)
        return "\(start) to \(end)"
    }
}
