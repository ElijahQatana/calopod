import CalopodSnapshot
import SwiftUI

/// The next two weeks as a day schedule. With calendars chosen on the Mac it shows their events;
/// without, only the busy time, which carries no titles.
struct CalendarTab: View {
    var context: SnapshotContext
    var filter: CalendarFilter
    @Bindable var navigation: Navigation

    var body: some View {
        if let id = navigation.calendarEventID, let event = context.snapshot.days.flatMap(\.events).first(where: { $0.id == id }) {
            EventDetailScreen(
                item: InboxItem(event), context: context, untitled: "Busy",
                back: BackAction(label: "Calendar") { navigation.calendarEventID = nil })
        } else {
            schedule
        }
    }

    private var schedule: some View {
        let snapshot = context.snapshot
        let hasEvents = !snapshot.days.isEmpty
        let days = DaySchedule.schedules(from: snapshot.availability)
        let selected = navigation.calendarDay
        let day = days.first { $0.day == selected } ?? days.first { $0.interval.contains(context.now) } ?? days.first
        let week = AvailabilityFigures.week(from: snapshot.availability)
        let figures = week.first { $0.day == selected } ?? week.first { $0.interval.contains(context.now) } ?? week.first
        return Screen(
            title: "Calendar", subtitle: "\(hasEvents ? "Events" : "Busy time") \(context.fromMac)"
        ) {
            Picker("View", selection: $navigation.calendarMode) {
                ForEach(Navigation.CalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if context.isStale {
                StaleBanner(lastUpdate: snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                if navigation.calendarMode == .availability {
                    if let figures {
                        AvailabilityPage(week: week, day: figures) { navigation.calendarDay = $0 }
                    } else {
                        Card { Text("No availability has been published.").font(Theme.Fonts.body).padding(16) }
                    }
                } else if let day {
                    DayStrip(days: days, selected: day.day) { navigation.calendarDay = $0 }
                    if hasEvents {
                        FilterRow(snapshot: snapshot, filter: filter)
                        let events = DayEvents.make(from: snapshot.days.first { $0.day == day.day }, hidden: filter.hiding(in: snapshot), in: day)
                        EventDay(
                            events: events, day: day, snapshot: snapshot,
                            empty: filter.scope(in: snapshot) == .destinations ? "No events on destination calendars this day." : "No events on this day."
                        ) { navigation.calendarEventID = $0.id }
                    } else {
                        NoCalendarsNote()
                        SectionLabel(text: "Busy")
                        BusyList(day: day)
                    }
                } else {
                    Card { Text("No busy time has been published.").font(Theme.Fonts.body).padding(16) }
                }
                ReadOnlyFoot(text: "Based on your Mac's last update at \(snapshot.publishedAt.formatted(timeFormat)).")
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

private struct NoCalendarsNote: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("No calendars chosen yet").font(Theme.Fonts.bodyStrong)
                Text("To see events here, open Calopod on your Mac, go to Settings, then iPhone, and switch on the calendars to share.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }
}

/// Two chips: which kind of calendar to show, then one for the calendars on or off, which opens a list.
/// The row is the same size for any number of calendars.
private struct FilterRow: View {
    var snapshot: Snapshot
    var filter: CalendarFilter
    @State private var listOpen = false

    var body: some View {
        let listed = CalendarFilter.listed(in: snapshot).filter { filter.inScope($0, in: snapshot) }
        let count = filter.count(in: snapshot)
        HStack(spacing: 8) {
            if CalendarFilter.knowsRoles(in: snapshot) { scopeChip }
            ViewThatFits(in: .horizontal) {
                calendarsChip(listed: listed, count: count, word: true)
                calendarsChip(listed: listed, count: count, word: false)
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $listOpen) {
            CalendarList(snapshot: snapshot, filter: filter) { listOpen = false }
                .presentationDetents([.large])
        }
    }

    private var scopeChip: some View {
        Menu {
            Picker("Show", selection: Binding(get: { filter.scope }, set: { filter.setScope($0) })) {
                ForEach(CalendarFilter.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(filter.scope.rawValue)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .chipStyle(on: true)
        }
        .accessibilityLabel("Show")
        .accessibilityValue(filter.scope.rawValue)
    }

    private func calendarsChip(listed: [CalendarEntry], count: (shown: Int, total: Int), word: Bool) -> some View {
        Button { listOpen = true } label: {
            HStack(spacing: 7) {
                StackedDots(colors: listed.filter { filter.isShown($0.id) }.prefix(4).map(Theme.calendarColor))
                if word { Text("Calendars") }
                Text("\(count.shown) of \(count.total)").foregroundStyle(Theme.secondary)
            }
            .chipStyle(on: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendars")
        .accessibilityValue("\(count.shown) of \(count.total) shown")
    }
}

private extension View {
    func chipStyle(on: Bool) -> some View {
        font(Theme.Fonts.caption)
            .lineLimit(1)
            .padding(.horizontal, 12).frame(height: 34)
            .foregroundStyle(Theme.text)
            .background(on ? Theme.card : Theme.fill, in: Capsule())
            .shadow(color: Theme.text.opacity(on ? 0.06 : 0), radius: 3, y: 1)
    }
}

private struct StackedDots: View {
    var colors: [Color]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Circle().fill(color).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.screen, lineWidth: 1.5))
                    .zIndex(Double(-index))
            }
            if colors.isEmpty { Circle().strokeBorder(Theme.faint, lineWidth: 1.5).frame(width: 12, height: 12) }
        }
    }
}

/// Every calendar the Mac sent events for with a switch, sources first and then destinations.
private struct CalendarList: View {
    var snapshot: Snapshot
    var filter: CalendarFilter
    var done: () -> Void

    var body: some View {
        let listed = CalendarFilter.listed(in: snapshot)
        let split = CalendarFilter.knowsRoles(in: snapshot)
        let sources = listed.filter { $0.destination != true }
        let destinations = listed.filter { $0.destination == true }
        VStack(spacing: 0) {
            Text("Show calendars").font(Theme.Fonts.heading).padding(.top, 22).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if split { SectionLabel(text: "Sources") }
                    group(sources)
                    if split && !destinations.isEmpty {
                        SectionLabel(text: "Destinations").padding(.top, 8)
                        group(destinations)
                    }
                    Text("Hiding a calendar only changes this screen. The free and busy totals count all of them.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.faint).padding(.horizontal, 4).padding(.top, 8)
                }
                .padding(.horizontal, Theme.sidePadding)
            }
            HStack {
                Button("Reset") { filter.reset() }
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Done", action: done).fontWeight(.semibold).foregroundStyle(Theme.accent)
            }
            .font(Theme.Fonts.bodyStrong)
            .padding(.horizontal, Theme.sidePadding + 4).padding(.vertical, 14)
        }
        .background(Theme.screen.ignoresSafeArea())
    }

    private func group(_ calendars: [CalendarEntry]) -> some View {
        Card {
            ForEach(calendars, id: \.id) { calendar in
                Toggle(isOn: Binding(get: { filter.isShown(calendar.id) }, set: { filter.setShown($0, for: calendar.id) })) {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.calendarColor(calendar)).frame(width: 12, height: 12)
                        Text(calendar.name).font(Theme.Fonts.body)
                    }
                }
                .tint(Theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                if calendar.id != calendars.last?.id { Divider().overlay(Theme.line) }
            }
        }
    }
}

/// All-day events in a strip, then the timed ones on an hour grid with overlaps side by side.
private struct EventDay: View {
    var events: DayEvents
    var day: DaySchedule
    var snapshot: Snapshot
    var empty: String
    var open: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 52
    private let labelWidth: CGFloat = 44

    var body: some View {
        if events.allDay.isEmpty && events.blocks.isEmpty {
            Card { Text(empty).font(Theme.Fonts.body).padding(16) }
        }
        if !events.allDay.isEmpty {
            SectionLabel(text: "All day")
            Card {
                ForEach(events.allDay, id: \.id) { event in
                    Button { open(event) } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(color(event)).frame(width: 4, height: 22)
                            Text(event.displayTitle).font(Theme.Fonts.bodyStrong).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    if event.id != events.allDay.last?.id { Divider().overlay(Theme.line) }
                }
            }
            .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
        }
        if !events.blocks.isEmpty {
            SectionLabel(text: "Schedule")
            grid
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = day.timeZone
        return calendar
    }

    /// Whole hours shown: 8 to 18 at least, wider when events fall outside.
    private var hours: Range<Int> {
        let cut = calendar
        let first = events.blocks.map { cut.component(.hour, from: $0.interval.start) }.min() ?? 8
        let lastEnd = events.blocks.map(\.interval.end).max() ?? day.interval.start
        let last = lastEnd >= day.interval.end ? 24 : cut.component(.hour, from: lastEnd) + (cut.component(.minute, from: lastEnd) > 0 ? 1 : 0)
        return min(first, 8)..<max(last, 18)
    }

    private var grid: some View {
        let hours = hours
        let top = day.interval.start.addingTimeInterval(TimeInterval(hours.lowerBound) * 3600)
        return Card {
            GeometryReader { proxy in
                let width = proxy.size.width - labelWidth - 12
                ZStack(alignment: .topLeading) {
                    ForEach(hours.lowerBound..<hours.upperBound, id: \.self) { hour in
                        let y = CGFloat(hour - hours.lowerBound) * hourHeight
                        Text(hourLabel(hour)).font(.caption2).foregroundStyle(Theme.faint)
                            .frame(width: labelWidth - 6, alignment: .trailing).offset(x: 0, y: y - 6)
                        Rectangle().fill(Theme.line).frame(width: proxy.size.width - labelWidth, height: 1).offset(x: labelWidth, y: y)
                    }
                    ForEach(events.blocks) { block in
                        let slot = width / CGFloat(block.columns)
                        let y = CGFloat(block.interval.start.timeIntervalSince(top) / 3600) * hourHeight
                        let height = max(CGFloat(block.interval.duration / 3600) * hourHeight - 2, 22)
                        Button { open(block.event) } label: { blockView(block, height: height) }
                            .buttonStyle(.plain)
                            .frame(width: slot - 3, height: height)
                            .offset(x: labelWidth + slot * CGFloat(block.column), y: y + 1)
                    }
                }
            }
            .frame(height: CGFloat(hours.count) * hourHeight + 6)
            .padding(.vertical, 10).padding(.horizontal, 6)
        }
        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
    }

    private func blockView(_ block: EventBlock, height: CGFloat) -> some View {
        let color = color(block.event)
        let untitled = block.event.title == nil
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.event.displayTitle).font(.caption.weight(.semibold)).lineLimit(height > 40 ? 2 : 1)
                if height > 40 { Text(timeText(block)).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            .foregroundStyle(untitled ? Theme.secondary : Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(untitled ? 0.12 : 0.25), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.event.displayTitle), \(timeText(block)), \(snapshot.calendar(for: block.event.calendarID)?.name ?? "")")
    }

    private func color(_ event: CalendarEvent) -> Color {
        Theme.calendarColor(snapshot.calendar(for: event.calendarID))
    }

    private func hourLabel(_ hour: Int) -> String {
        guard let date = calendar.date(byAdding: .hour, value: hour, to: day.interval.start) else { return "" }
        return date.formatted(Date.FormatStyle(timeZone: day.timeZone).hour())
    }

    private func timeText(_ block: EventBlock) -> String {
        let start = block.continuesFromYesterday ? "Yesterday" : format(block.interval.start, in: day.timeZone)
        let end = block.continuesTomorrow ? "tomorrow" : format(block.interval.end, in: day.timeZone)
        return "\(start) to \(end)"
    }
}
