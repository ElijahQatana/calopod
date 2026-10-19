import CalopodSnapshot
import SwiftUI

/// The Availability side of Calendar: the week with a dot per day, then the chosen day's free and
/// busy time as the Mac worked it out. Nothing here is calculated on the phone.
struct AvailabilityPage: View {
    var week: [AvailabilityFigures]
    var day: AvailabilityFigures
    var select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let first = week.first, let last = week.last {
                Text("\(label(first.interval.start, first.timeZone)) to \(label(last.interval.start, last.timeZone))")
                    .font(Theme.Fonts.heading).padding(.horizontal, 4)
            }
            WeekRow(week: week, selected: day.day, select: select)
            Totals(day: day)
            if let summary = day.summary() {
                Text(summary).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary).padding(.horizontal, 4)
            }
            Card {
                if let worked = day.worked {
                    Ranges(title: "Free windows", ranges: worked.free, empty: "No free time inside working hours.", day: day)
                    Divider().overlay(Theme.line)
                }
                Ranges(title: "Busy", ranges: day.busy, empty: "Nothing busy.", day: day)
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
    }

    private func label(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(timeZone: zone).month(.abbreviated).day())
    }
}

private struct WeekRow: View {
    var week: [AvailabilityFigures]
    var selected: String
    var select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(week, id: \.day) { day in
                    let on = day.day == selected
                    let style = { (format: Date.FormatStyle) in day.interval.start.formatted(format) }
                    Button { select(day.day) } label: {
                        VStack(spacing: 4) {
                            Text(style(Date.FormatStyle(timeZone: day.timeZone).weekday(.narrow))).font(.caption2)
                                .foregroundStyle(Theme.secondary)
                            Text(style(Date.FormatStyle(timeZone: day.timeZone).day())).font(Theme.Fonts.bodyStrong).monospacedDigit()
                            dot(day.worked?.status)
                        }
                        .frame(width: 44).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent : Theme.line, lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel(style(Date.FormatStyle(timeZone: day.timeZone).weekday(.wide).day().month(.wide)))
                    .accessibilityValue(day.worked?.status.words ?? "")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }

    /// A color for how full the day is, an empty ring for a day off, nothing when the Mac sent no status.
    @ViewBuilder private func dot(_ status: AvailabilityStatus?) -> some View {
        if let status, let color = status.color {
            Circle().fill(color).frame(width: 9, height: 9)
        } else if status != nil {
            Circle().strokeBorder(Theme.faint, lineWidth: 1).frame(width: 9, height: 9)
        } else {
            Color.clear.frame(width: 9, height: 9)
        }
    }
}

private struct Totals: View {
    var day: AvailabilityFigures

    var body: some View {
        if let free = day.freeTime {
            HStack(alignment: .top, spacing: 10) {
                Tile(value: DurationText.text(free), title: "Free", note: day.hoursLine())
                Tile(value: DurationText.text(day.busyTime), title: "Busy", note: day.overlapsLine, flagged: (day.worked?.overlaps ?? 0) > 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // An older Mac sends no working hours, so a free total would only be a guess.
            Tile(value: DurationText.text(day.busyTime), title: "Busy", note: day.hoursLine())
        }
    }
}

private struct Tile: View {
    var value: String
    var title: String
    var note: String?
    var flagged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Fonts.heading).monospacedDigit()
            Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.secondary)
            if let note {
                Text(note).font(.caption2).foregroundStyle(flagged ? Theme.bad : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

private struct Ranges: View {
    var title: String
    var ranges: [DateInterval]
    var empty: String
    var day: AvailabilityFigures

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Fonts.bodyStrong)
            if ranges.isEmpty { Text(empty).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary) }
            ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                HStack {
                    Text(day.timeRange(range)).font(Theme.Fonts.body).monospacedDigit()
                    Spacer(minLength: 8)
                    Text(DurationText.text(range.duration)).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}
