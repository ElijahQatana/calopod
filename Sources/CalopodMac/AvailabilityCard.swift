import CalopodCommands
import CalopodSync
import SwiftUI

extension AvailabilityLoad {
    var words: String {
        switch self {
        case .dayOff: "day off"
        case .mostlyFree: "mostly free"
        case .tight: "tight"
        case .overbooked: "overbooked"
        }
    }

    var tint: Color? {
        switch self {
        case .dayOff: nil
        case .mostlyFree: Theme.good
        case .tight: Theme.caution
        case .overbooked: Theme.bad
        }
    }
}

enum AvailabilityText {
    static func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func overlaps(_ count: Int) -> String { count == 1 ? "1 overlap" : "\(count) overlaps" }

    /// The working window of the day, or why there is none.
    static func hours(_ report: AvailabilityDayReport) -> String {
        guard let windows = report.result.workingWindows else { return "Working hours are not applied." }
        guard let first = windows.first, let last = windows.last else { return "Day off. Anything you book counts as busy." }
        return "Working hours \(range(first.start, last.end))."
    }
}

/// The Availability page of Calendar: the week card with the same out of date warnings as the schedule.
struct AvailabilityPage: View {
    @Environment(CalendarModel.self) private var schedule
    @Environment(AvailabilityModel.self) private var availability
    let openSettings: () -> Void

    var body: some View {
        let notices = ScheduleLayout.notices(
            calendars: schedule.calendars, hidden: [], range: availability.range, now: Date(),
            name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) })
        GeometryReader { proxy in
            ScrollView {
                AvailabilityCard(model: availability, notices: notices, openSettings: openSettings)
                    .padding(.horizontal, 18).padding(.bottom, Theme.Page.bottom)
                    .frame(maxWidth: Theme.Page.maxWidth, minHeight: proxy.size.height, alignment: .top)
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await availability.reload() }
        .onChange(of: schedule.schedule) { Task { await availability.reload() } }
    }
}

/// Today's free and busy time on one row, for Overview. It opens the Availability page.
struct AvailabilitySummary: View {
    let model: AvailabilityModel
    var glance: AvailabilityGlance = .line
    let open: () -> Void

    var body: some View {
        CardSection(header: OverviewSectionHeader(title: "Availability today", link: "Open Availability", action: open)) {
            CardRow { content }
            glanceRow
        }
        .task { await model.goToToday() }
    }

    /// The bar or the next days under the line, when the window has room for them.
    @ViewBuilder
    private var glanceRow: some View {
        if !model.loadFailed, glance != .line, let report = model.report(for: model.calendar.startOfDay(for: Date())) {
            CardRow(dense: true) {
                if glance == .bar {
                    AvailabilityDayBar(report: report)
                } else {
                    AvailabilityDayChips(model: model, days: Array(model.days.filter { $0 >= report.day.start }.prefix(3)), compact: true)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loadFailed {
            Text("Availability could not be read.").foregroundStyle(.secondary)
        } else if let report = model.report(for: model.calendar.startOfDay(for: Date())) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                figure("Free", EventDuration.total(report.summary.freeSeconds))
                figure("Busy", EventDuration.total(report.summary.busySeconds))
                Text(AvailabilityText.hours(report)).font(Theme.Fonts.secondary).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Reading availability").foregroundStyle(.secondary)
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Theme.Fonts.bodySemibold).monospacedDigit()
            Text(title).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
        }
    }
}

/// Free and busy time for a week on the Availability page: a dot per day, the totals for the chosen day, and its
/// free windows and busy blocks. Free time counts only inside working hours.
struct AvailabilityCard: View {
    let model: AvailabilityModel
    let notices: [String]
    let openSettings: () -> Void
    private static let listLimit = 6

    var body: some View {
        CardSection(
            header: HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(weekTitle).font(Theme.Fonts.sectionTitle)
                Spacer(minLength: 8)
                Button("Today") { Task { await model.goToToday() } }
                    .buttonStyle(.bare).font(Theme.Fonts.secondarySemibold).foregroundStyle(Theme.accent)
                weekButton("chevron.left", "Previous week", -1)
                weekButton("chevron.right", "Next week", 1)
            },
            fills: true,
            content: {
                ForEach(notices, id: \.self) { notice in CardRow { Banner(kind: .caution, text: notice) } }
                if model.loadFailed {
                    CardRow { Text("Availability could not be read.").foregroundStyle(.secondary) }
                } else {
                    CardRow { strip }
                    if let report = model.selectedReport { detail(report) }
                    CardRow {
                        Button("Change working hours in Settings", action: openSettings)
                            .buttonStyle(.bare).font(Theme.Fonts.secondarySemibold).foregroundStyle(Theme.accent)
                    }
                }
            })
    }

    private var weekTitle: String {
        guard let first = model.days.first, let last = model.days.last else { return "Week" }
        let day = Date.FormatStyle().day().month(.abbreviated)
        return "\(first.formatted(day)) to \(last.formatted(day))"
    }

    private func weekButton(_ symbol: String, _ label: String, _ weeks: Int) -> some View {
        Button { Task { await model.step(weeks) } } label: { Image(systemName: symbol).font(Theme.Fonts.smallIcon) }
            .buttonStyle(.bare).foregroundStyle(Theme.accent).accessibilityLabel(label)
    }

    // MARK: Day strip

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(model.days, id: \.self) { day in
                let load = model.report(for: day)?.summary.load
                let chosen = day == model.selected
                Button { model.selected = day } label: {
                    VStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(Theme.Fonts.tinyMedium).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day())).font(Theme.Fonts.bodySemibold).monospacedDigit()
                        dot(load)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(chosen ? Theme.accent : Theme.paneLine, lineWidth: chosen ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", " + (load?.words ?? "not loaded")
                    + (model.isToday(day) ? ", today" : ""))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func dot(_ load: AvailabilityLoad?) -> some View {
        if let tint = load?.tint {
            Circle().fill(tint).frame(width: 10, height: 10)
        } else {
            // A day off, or nothing read yet: an empty ring rather than a status color.
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 10, height: 10)
        }
    }

    // MARK: Chosen day

    @ViewBuilder
    private func detail(_ report: AvailabilityDayReport) -> some View {
        let summary = report.summary
        CardRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    tile("Free", EventDuration.total(summary.freeSeconds), note: AvailabilityText.hours(report))
                    tile("Busy", EventDuration.total(summary.busySeconds), note: AvailabilityText.overlaps(summary.overlaps),
                         flagged: summary.overlaps > 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("\(report.day.start.formatted(.dateTime.weekday(.wide))) is \(summary.load.words).")
                    .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
        }
        CardRow {
            CardColumns(minColumnWidth: 300) {
                list("Free windows", report.result.free, empty: "No free time inside working hours.")
                list("Busy", report.result.busy, empty: "Nothing busy.")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tile(_ title: String, _ value: String, note: String, flagged: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.Fonts.heading).monospacedDigit()
            Text(title).font(Theme.Fonts.secondarySemibold).foregroundStyle(.secondary)
            Text(note).font(Theme.Fonts.tiny).foregroundStyle(flagged ? Theme.badText : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.paneLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func list(_ title: String, _ intervals: [AvailabilityInterval], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Fonts.bodySemibold)
            if intervals.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(Array(intervals.prefix(Self.listLimit).enumerated()), id: \.offset) { _, interval in
                HStack {
                    Text(AvailabilityText.range(interval.start, interval.end)).monospacedDigit()
                    Spacer(minLength: 8)
                    Text(EventDuration.text(interval.end.timeIntervalSince(interval.start)))
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
            }
            if intervals.count > Self.listLimit {
                Text("and \(intervals.count - Self.listLimit) more").foregroundStyle(.secondary)
            }
        }
    }
}
