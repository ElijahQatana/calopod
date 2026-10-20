import CalopodSnapshot
import Foundation

/// One busy stretch inside a day. The flags say it carries on past midnight.
struct BusyBlock: Equatable {
    var interval: DateInterval
    var continuesFromYesterday = false
    var continuesTomorrow = false
}

/// A local day's busy blocks worked out from the published intervals.
struct DaySchedule: Equatable {
    var day: String
    var timeZone: TimeZone
    var interval: DateInterval
    var busy: [BusyBlock]

    /// One schedule per published day. A busy stretch is cut to each day it touches, so it counts
    /// whether or not the Mac cut it, and overlapping intervals are counted once. Time outside working
    /// hours is busy here too, because this is the whole day.
    static func schedules(from records: [AvailabilityDay]) -> [DaySchedule] {
        let all = records.flatMap { $0.busy + ($0.outside ?? []).map { BusyInterval(start: $0.start, end: $0.end) } }
            .filter { $0.end > $0.start }
        return records.compactMap { record in
            guard let timeZone = TimeZone(identifier: record.timeZoneIdentifier),
                let interval = localDay(record.day, in: timeZone)
            else { return nil }
            let blocks = merged(all.compactMap { DateInterval(start: $0.start, end: $0.end).intersection(with: interval) })
            return DaySchedule(
                day: record.day, timeZone: timeZone, interval: interval,
                busy: blocks.map { block in
                    BusyBlock(
                        interval: block,
                        continuesFromYesterday: block.start == interval.start && all.contains { $0.start < interval.start && $0.end > interval.start },
                        continuesTomorrow: block.end == interval.end && all.contains { $0.start < interval.end && $0.end > interval.end })
                })
        }
        .sorted { $0.interval.start < $1.interval.start }
    }

    static func localDay(_ key: String, in timeZone: TimeZone) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for next in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, next.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, next.end))
            } else {
                result.append(next)
            }
        }
        return result
    }
}

enum DurationText {
    /// "45 min", "3 hr" or "5 hr 30 min".
    static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }
}

extension DurationText {
    /// "45m", "2h" or "1h 30m", the compact form for a row.
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(rest)m"
        }
    }
}
