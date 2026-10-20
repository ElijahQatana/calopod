import CalopodCommands
import CalopodSync
import SwiftUI

/// How much of Overview's availability section shows, as the window allows.
enum AvailabilityGlance {
    /// The free and busy line only.
    case line
    /// The line and a bar of the day's busy time.
    case bar
    /// The line and today with the next two days as small chips.
    case chips
    /// The chips, and the line without the working hours, for the smallest window.
    case tight
}

/// A status dot for one day's load, an empty ring for a day off or one not read yet.
struct LoadDot: View {
    let load: AvailabilityLoad?

    var body: some View {
        if let tint = load?.tint {
            Circle().fill(tint).frame(width: 10, height: 10)
        } else {
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 10, height: 10)
        }
    }
}

/// Days as small chips with a status dot each. Today has the accent outline.
struct AvailabilityDayChips: View {
    let model: AvailabilityModel
    let days: [Date]
    /// One line per chip, for the little room Overview has in a small window.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let load = model.report(for: day)?.summary.load
                let today = model.isToday(day)
                chip(day, load)
                .frame(maxWidth: .infinity).padding(.vertical, compact ? 4 : 6)
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(today ? Theme.accent : Theme.paneLine, lineWidth: today ? 2 : 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", " + (load?.words ?? "not loaded")
                    + (today ? ", today" : ""))
            }
        }
    }

    private func chip(_ day: Date, _ load: AvailabilityLoad?) -> some View {
        let weekday = Text(day.formatted(.dateTime.weekday(.abbreviated))).font(Theme.Fonts.tinyMedium).foregroundStyle(.secondary)
        let number = Text(day.formatted(.dateTime.day())).font(Theme.Fonts.bodySemibold).monospacedDigit()
        return Group {
            if compact {
                HStack(spacing: 6) { weekday; number; LoadDot(load: load) }
            } else {
                VStack(spacing: 3) { weekday; number; LoadDot(load: load) }
            }
        }
    }
}

/// The week as chips in a card of their own, for a window with room to spare.
struct AvailabilityWeekSection: View {
    let model: AvailabilityModel
    let open: () -> Void

    var body: some View {
        CardSection(header: OverviewSectionHeader(title: "This week", link: "Open Availability", action: open)) {
            CardRow { AvailabilityDayChips(model: model, days: model.days) }
        }
    }
}

/// Busy time laid over the working part of the day.
struct AvailabilityDayBar: View {
    let report: AvailabilityDayReport

    var body: some View {
        if let windows = report.result.workingWindows, let first = windows.first, let last = windows.last {
            let span = max(last.end.timeIntervalSince(first.start), 1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.good.opacity(0.18))
                    ForEach(Array(report.result.busy.enumerated()), id: \.offset) { _, busy in
                        let from = max(0, busy.start.timeIntervalSince(first.start)) / span
                        let to = min(1, busy.end.timeIntervalSince(first.start) / span)
                        if to > from {
                            Capsule().fill(Theme.accent.opacity(0.75))
                                .frame(width: (to - from) * proxy.size.width)
                                .offset(x: from * proxy.size.width)
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
    }
}
