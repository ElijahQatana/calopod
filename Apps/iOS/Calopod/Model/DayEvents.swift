import CalopodSnapshot
import Foundation

/// One timed event placed on a day. Overlapping events share the width: `column` is the slot it
/// takes and `columns` how many slots its cluster of overlaps needs.
struct EventBlock: Equatable, Identifiable {
    var event: CalendarEvent
    var interval: DateInterval
    var column = 0
    var columns = 1
    var continuesFromYesterday = false
    var continuesTomorrow = false

    var id: String { event.id }
}

/// The events of one local day, ready to draw: all-day ones for a strip, the rest as blocks.
struct DayEvents: Equatable {
    var allDay: [CalendarEvent]
    var blocks: [EventBlock]

    /// Shortest stretch a block takes, so a zero-length event is still there to tap.
    static let shortest: TimeInterval = 15 * 60

    /// Events of calendars in `hidden` are left out, and Calopod's copies unless `copies` is set. An event
    /// that crosses midnight is cut to the day.
    static func make(from record: CalendarDay?, hidden: Set<String>, copies: Bool = true, in day: DaySchedule) -> DayEvents {
        let events = (record?.events ?? []).filter { !hidden.contains($0.calendarID) && (copies || !$0.isCopy) }
        let timed: [EventBlock] = events.filter { !$0.isAllDay }.compactMap { event in
            let end = max(event.endsAt, event.startsAt.addingTimeInterval(shortest))
            guard let part = DateInterval(start: event.startsAt, end: end).intersection(with: day.interval) else { return nil }
            return EventBlock(
                event: event, interval: part,
                continuesFromYesterday: event.startsAt < day.interval.start,
                continuesTomorrow: end > day.interval.end)
        }
        .sorted { ($0.interval.start, $1.interval.end, $0.id) < ($1.interval.start, $0.interval.end, $1.id) }
        return DayEvents(allDay: events.filter(\.isAllDay).sorted { ($0.title ?? "") < ($1.title ?? "") }, blocks: placed(timed))
    }

    /// Puts each block in the first free column of its cluster. A cluster is a run of events that
    /// overlap each other one after another, and every block in it gets the cluster's column count.
    private static func placed(_ blocks: [EventBlock]) -> [EventBlock] {
        var result: [EventBlock] = []
        var cluster: [EventBlock] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func close() {
            result += cluster.map { var block = $0; block.columns = columnEnds.count; return block }
            cluster = []
            columnEnds = []
        }
        for var block in blocks {
            if block.interval.start >= clusterEnd { close() }
            let free = columnEnds.firstIndex { $0 <= block.interval.start } ?? columnEnds.count
            if free == columnEnds.count { columnEnds.append(block.interval.end) } else { columnEnds[free] = block.interval.end }
            block.column = free
            cluster.append(block)
            clusterEnd = max(clusterEnd, block.interval.end)
        }
        close()
        return result
    }
}

extension CalendarEvent {
    /// A private event comes without its title.
    var displayTitle: String { title ?? "Busy" }
}
