import CalopodSnapshot
import SwiftUI

/// One day of free, busy and outside time as the Mac published it. Totals only add up the published
/// lists, and nothing is worked out from busy time here.
struct AvailabilityFigures: Equatable {
    struct Worked: Equatable {
        var working: DateInterval?
        var free: [DateInterval]
        var overlaps: Int
        var status: AvailabilityStatus
    }

    struct Outside: Equatable {
        var range: DateInterval
        var side: HoursSide
    }

    var day: String
    var timeZone: TimeZone
    var interval: DateInterval
    /// Busy time inside working hours when the Mac sent working hours.
    var busy: [DateInterval]
    /// Busy time before or after working hours. Nil for a feed from a Mac that does not send it.
    var outside: [Outside]?
    /// Nil for a feed from an older Mac, which has the busy time only.
    var worked: Worked?

    var busyTime: TimeInterval { busy.reduce(0) { $0 + $1.duration } }
    var outsideTime: TimeInterval { (outside ?? []).reduce(0) { $0 + $1.range.duration } }
    var freeTime: TimeInterval? { worked.map { $0.free.reduce(0) { $0 + $1.duration } } }

    init?(_ record: AvailabilityDay) {
        guard let timeZone = TimeZone(identifier: record.timeZoneIdentifier),
            let interval = DaySchedule.localDay(record.day, in: timeZone)
        else { return nil }
        day = record.day
        self.timeZone = timeZone
        self.interval = interval
        busy = Self.intervals(record.busy)
        outside = record.outside.map { blocks in
            blocks.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
                .map { Outside(range: DateInterval(start: $0.start, end: $0.end), side: $0.side) }
        }
        if let free = record.free, let status = record.status {
            worked = Worked(
                working: record.working.flatMap { Self.intervals([$0]).first }, free: Self.intervals(free),
                overlaps: record.overlaps ?? 0, status: status)
        }
    }

    /// The published days in date order. A day with an unreadable date or zone is left out.
    static func week(from records: [AvailabilityDay]) -> [AvailabilityFigures] {
        records.compactMap(AvailabilityFigures.init).sorted { $0.interval.start < $1.interval.start }
    }

    private static func intervals(_ list: [BusyInterval]) -> [DateInterval] {
        list.filter { $0.end > $0.start }.map { DateInterval(start: $0.start, end: $0.end) }.sorted { $0.start < $1.start }
    }

    // MARK: Words

    func timeRange(_ range: DateInterval, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        return "\(range.start.formatted(style)) to \(range.end.formatted(style))"
    }

    func hoursLine(locale: Locale = .current) -> String {
        guard let worked else { return "Working hours need an updated Mac." }
        if let working = worked.working { return "Working hours \(timeRange(working, locale: locale))." }
        if worked.status == .dayOff {
            return outside == nil ? "Day off. Anything you book counts as busy." : "Day off. Anything you book is outside working hours."
        }
        return "Working hours are not applied."
    }

    /// "Monday is mostly free." Nil when the Mac sent no status.
    func summary(locale: Locale = .current) -> String? {
        guard let status = worked?.status else { return nil }
        let weekday = interval.start.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.wide))
        return status == .dayOff ? "\(weekday) is a day off." : "\(weekday) is \(status.words)."
    }

    var overlapsLine: String? {
        guard let count = worked?.overlaps else { return nil }
        return count == 1 ? "1 overlap" : "\(count) overlaps"
    }
}

extension HoursSide {
    var words: String {
        switch self {
        case .before: "Before hours"
        case .after: "After hours"
        case .dayOff: "Day off"
        }
    }
}

extension AvailabilityStatus {
    var words: String {
        switch self {
        case .mostlyFree: "mostly free"
        case .tight: "tight"
        case .overbooked: "overbooked"
        case .dayOff: "day off"
        }
    }

    /// Nil for a day off, which gets an empty ring instead of a color.
    var color: Color? {
        switch self {
        case .mostlyFree: Theme.good
        case .tight: Theme.caution
        case .overbooked: Theme.bad
        case .dayOff: nil
        }
    }
}
