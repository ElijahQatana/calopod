import CalopodCommands
import Foundation

/// Pure layout and display rules for the Calendar screen.
enum ScheduleLayout {
    /// The seven days of the week that contains `date`, as start-of-day dates.
    static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    struct Placement: Equatable, Identifiable {
        var id: String { event.id }
        let event: ScheduleEvent
        let column: Int
        let columns: Int
        /// Minutes from midnight, clipped to this day.
        let top: Double
        let height: Double
    }

    /// Timed events on one day, with side by side columns for overlaps. Short events take
    /// `minimumMinutes` of room so a title is never squeezed into a sliver.
    static func placements(
        _ events: [ScheduleEvent], on day: Date, calendar: Calendar, minimumMinutes: Double = 30
    ) -> [Placement] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let items = events
            .filter { !$0.isAllDay && $0.endsAt > dayStart && $0.startsAt < dayEnd }
            .map { event -> (event: ScheduleEvent, top: Double, end: Double) in
                let top = max(event.startsAt, dayStart).timeIntervalSince(dayStart) / 60
                let end = min(event.endsAt, dayEnd).timeIntervalSince(dayStart) / 60
                return (event, top, min(max(end, top + minimumMinutes), 1440))
            }
            .sorted { ($0.top, $0.end, $0.event.id) < ($1.top, $1.end, $1.event.id) }

        var result: [Placement] = []
        var cluster: [(event: ScheduleEvent, top: Double, end: Double, column: Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func flush() {
            let columns = max(columnEnds.count, 1)
            for item in cluster {
                result.append(Placement(
                    event: item.event, column: item.column, columns: columns,
                    top: item.top, height: item.end - item.top))
            }
            cluster = []
            columnEnds = []
        }

        for item in items {
            if item.top >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= item.top } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(item.end) } else { columnEnds[column] = item.end }
            cluster.append((item.event, item.top, item.end, column))
            clusterEnd = max(clusterEnd, item.end)
        }
        flush()
        return result
    }

    static func allDay(_ events: [ScheduleEvent], on day: Date, calendar: Calendar) -> [ScheduleEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.isAllDay && $0.endsAt > start && $0.startsAt < end }
            .sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
    }

    enum Treatment: Equatable {
        /// A Busy copy Calopod made.
        case copy
        case needsRSVP
        case declined
        /// Accepted, tentative, or your own.
        case tinted
    }

    static func treatment(for event: ScheduleEvent) -> Treatment {
        if event.isCopy { return .copy }
        switch event.response {
        case .needsResponse: return .needsRSVP
        case .declined: return .declined
        default: return .tinted
        }
    }

    /// Overlap rings and the changed dot sit on top of the base treatment. Copies get neither.
    static func showsOverlap(_ event: ScheduleEvent) -> Bool { !event.isCopy && !event.overlaps.isEmpty }
    static func showsChange(_ event: ScheduleEvent) -> Bool { !event.isCopy && event.changedSinceViewed }

    /// One line per visible calendar whose local copy is old, missing, or does not reach the range.
    static func notices(
        calendars: [ScheduleCalendar], hidden: Set<String>, range: Range<Date>, now: Date
    ) -> [String] {
        calendars.filter { !hidden.contains($0.id) }.compactMap { calendar in
            switch calendar.freshness {
            case .unread:
                return "\(calendar.name) has not been read yet, so its events are missing."
            case .stale(let since):
                let when = since.map { " It was last read \(Format.ago(max(0, Int(now.timeIntervalSince($0)))))." } ?? ""
                return "\(calendar.name) could not be read.\(when) Events and overlaps may be missing."
            case .current:
                if let coverage = calendar.coverage,
                   coverage.lowerBound > range.lowerBound || coverage.upperBound < range.upperBound {
                    return "\(calendar.name) has not been read for these dates, so events may be missing."
                }
                return nil
            }
        }
    }
}
