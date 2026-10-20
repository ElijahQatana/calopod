import CalopodSnapshot
import SwiftUI

/// The next two weeks as a day schedule. With calendars chosen on the Mac it shows their events;
/// without, only the busy time, which carries no titles.
struct CalendarTab: View {
    var context: SnapshotContext
    var filter: CalendarFilter
    @Bindable var navigation: Navigation
    /// An event a tapped reminder asked to open. It is cleared once the event is shown.
    @Binding var requested: String?
    @State private var openEvent: CalendarEvent?

    var body: some View {
        Group {
            if let event = openEvent {
                EventDetailScreen(
                    item: InboxItem(event), context: context, untitled: "Busy", back: BackAction(label: "Calendar") { openEvent = nil })
            } else {
                schedule
            }
        }
        .onChange(of: requested, initial: true) { _, id in
            guard let id else { return }
            openEvent = context.snapshot.days.flatMap(\.events).first { $0.id == id }
            requested = nil
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
            title: "Calendar", subtitle: "\(hasEvents ? "Events" : "Busy time") \(context.fromMac)",
            pinned: {
                Picker("View", selection: $navigation.calendarMode) {
                    ForEach(Navigation.CalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.sidePadding).padding(.top, 14)
            }
        ) {
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
                        CalendarChips(calendars: CalendarFilter.listed(in: snapshot), filter: filter)
                        let events = DayEvents.make(from: snapshot.days.first { $0.day == day.day }, hidden: filter.hidden, in: day)
                        EventDay(events: events, day: day, snapshot: snapshot) { openEvent = $0 }
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

/// One chip per calendar the Mac sent events for. Tapping shows or hides it on this phone.
private struct CalendarChips: View {
    var calendars: [CalendarEntry]
    var filter: CalendarFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Calendars")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(calendars, id: \.id) { calendar in
                        let on = filter.isShown(calendar.id)
                        Button { filter.setShown(!on, for: calendar.id) } label: {
                            HStack(spacing: 6) {
                                Circle().strokeBorder(Theme.calendarColor(calendar), lineWidth: 2)
                                    .background(Circle().fill(on ? Theme.calendarColor(calendar) : .clear))
                                    .frame(width: 10, height: 10)
                                Text(calendar.name)
                            }
                            .font(Theme.Fonts.caption)
                            .padding(.horizontal, 12).frame(height: 34)
                            .foregroundStyle(on ? Theme.text : Theme.secondary)
                            .background(on ? Theme.card : Theme.fill, in: Capsule())
                            .shadow(color: Theme.text.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(calendar.name)
                        .accessibilityValue(on ? "Shown" : "Hidden")
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
            Text("Hiding a calendar only changes this screen. The free and busy totals count all of them.")
                .font(Theme.Fonts.secondary).foregroundStyle(Theme.faint).padding(.horizontal, 4)
        }
    }
}

/// All-day events in a strip, then the timed ones on an hour grid with overlaps side by side.
private struct EventDay: View {
    var events: DayEvents
    var day: DaySchedule
    var snapshot: Snapshot
    var open: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 52
    private let labelWidth: CGFloat = 44

    var body: some View {
        if events.allDay.isEmpty && events.blocks.isEmpty {
            Card { Text("No events on this day.").font(Theme.Fonts.body).padding(16) }
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
