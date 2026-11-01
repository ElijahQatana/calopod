import CalopodStore
import Foundation

public enum AvailabilityIntervalKind: String, Equatable, Sendable {
    case busy
    case free
}

public struct AvailabilityInterval: Equatable, Sendable {
    public let kind: AvailabilityIntervalKind
    public let start: Date
    public let end: Date

    public init(kind: AvailabilityIntervalKind, start: Date, end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// Where busy time outside working hours falls on its day.
public enum OutsideSide: String, Equatable, Sendable {
    case before
    case after
    case dayOff
}

/// Busy time outside working hours, cut at midnight so each piece belongs to one day.
public struct OutsideInterval: Equatable, Sendable {
    public let side: OutsideSide
    public let start: Date
    public let end: Date

    public init(side: OutsideSide, start: Date, end: Date) {
        self.side = side
        self.start = start
        self.end = end
    }
}

public struct AvailabilityResult: Equatable, Sendable {
    /// Busy time inside working hours, or all busy time when working hours were not applied.
    public let busy: [AvailabilityInterval]
    public let free: [AvailabilityInterval]
    /// Busy time before or after working hours, and all of it on a day off.
    public let outside: [OutsideInterval]
    /// The working windows inside the range, or nil when working hours were not applied.
    public let workingWindows: [DateInterval]?
    /// Events that start before an earlier event has ended.
    public let overlaps: Int

    public init(
        busy: [AvailabilityInterval], free: [AvailabilityInterval],
        workingWindows: [DateInterval]? = nil, overlaps: Int = 0, outside: [OutsideInterval] = []
    ) {
        self.busy = busy
        self.free = free
        self.outside = outside
        self.workingWindows = workingWindows
        self.overlaps = overlaps
    }
}

/// Derives Busy and Free time across selected calendars. Only time ranges are used, so the result
/// is safe to share. With working hours, only time inside them counts as free or busy; busy time
/// outside them is reported separately as before hours, after hours or a day off.
public enum AvailabilityCalculator {
    public static func calculate(
        instances: [StoredNormalizedInstance],
        from windowStart: Date,
        through windowEnd: Date,
        workingHours: WorkingHours? = nil,
        timeZone: TimeZone = .current
    ) -> AvailabilityResult {
        guard windowStart < windowEnd else {
            return AvailabilityResult(busy: [], free: [])
        }

        // Clip busy intervals to the window first.
        let candidates = instances.compactMap { instance -> AvailabilityInterval? in
            guard !instance.isCancelled,
                  instance.availability != "free",
                  instance.endsAt > windowStart,
                  instance.startsAt < windowEnd else {
                return nil
            }
            return AvailabilityInterval(
                kind: .busy,
                start: max(instance.startsAt, windowStart),
                end: min(instance.endsAt, windowEnd)
            )
        }.sorted {
            ($0.start, $0.end) < ($1.start, $1.end)
        }

        // Sweep left to right, merging intervals that touch or overlap.
        let windows = workingHours.map {
            workingWindows($0, from: windowStart, through: windowEnd, timeZone: timeZone)
        }
        var merged: [AvailabilityInterval] = []
        var overlaps = 0
        for candidate in candidates {
            guard let current = merged.last else {
                merged.append(candidate)
                continue
            }
            // An overlap that only happens outside working hours does not crowd the working day.
            let sharedEnd = min(current.end, candidate.end)
            if candidate.start < sharedEnd,
               windows?.contains(where: { $0.start < sharedEnd && candidate.start < $0.end }) ?? true {
                overlaps += 1
            }
            if candidate.start <= current.end {
                merged[merged.count - 1] = AvailabilityInterval(
                    kind: .busy,
                    start: current.start,
                    end: max(current.end, candidate.end)
                )
            } else {
                merged.append(candidate)
            }
        }

        // Split the merged blocks into time inside working hours and time outside them.
        var busy = merged
        var outside: [OutsideInterval] = []
        if let workingHours {
            (busy, outside) = split(merged, hours: workingHours, from: windowStart, through: windowEnd, timeZone: timeZone)
        }

        // Free time is the gaps between the busy blocks, inside working hours if given.
        var free: [AvailabilityInterval] = []
        for range in windows ?? [DateInterval(start: windowStart, end: windowEnd)] {
            var cursor = range.start
            for interval in busy where interval.end > range.start && interval.start < range.end {
                if cursor < interval.start {
                    free.append(AvailabilityInterval(kind: .free, start: cursor, end: interval.start))
                }
                cursor = max(cursor, interval.end)
            }
            if cursor < range.end {
                free.append(AvailabilityInterval(kind: .free, start: cursor, end: range.end))
            }
        }

        return AvailabilityResult(
            busy: busy, free: free, workingWindows: windows, overlaps: overlaps, outside: outside)
    }

    /// Cuts each block at midnight and at the working window of its day. A day without a window
    /// is a day off.
    private static func split(
        _ blocks: [AvailabilityInterval], hours: WorkingHours, from start: Date, through end: Date,
        timeZone: TimeZone
    ) -> (inside: [AvailabilityInterval], outside: [OutsideInterval]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var inside: [AvailabilityInterval] = []
        var outside: [OutsideInterval] = []
        var dayStart = calendar.startOfDay(for: start)
        while dayStart < end, let next = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            defer { dayStart = next }
            let day = DateInterval(start: max(dayStart, start), end: min(next, end))
            let window = hours.window(forDayStarting: dayStart, calendar: calendar)
            for block in blocks where block.end > day.start && block.start < day.end {
                let piece = DateInterval(start: max(block.start, day.start), end: min(block.end, day.end))
                guard let window else {
                    outside.append(OutsideInterval(side: .dayOff, start: piece.start, end: piece.end))
                    continue
                }
                if piece.start < window.start {
                    outside.append(OutsideInterval(side: .before, start: piece.start, end: min(piece.end, window.start)))
                }
                if piece.end > window.start, piece.start < window.end {
                    inside.append(AvailabilityInterval(
                        kind: .busy, start: max(piece.start, window.start), end: min(piece.end, window.end)))
                }
                if piece.end > window.end {
                    outside.append(OutsideInterval(side: .after, start: max(piece.start, window.end), end: piece.end))
                }
            }
        }
        return (inside, outside)
    }

    /// The working window of each local day the range touches, cut to the range.
    static func workingWindows(
        _ hours: WorkingHours, from start: Date, through end: Date, timeZone: TimeZone
    ) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var windows: [DateInterval] = []
        var dayStart = calendar.startOfDay(for: start)
        while dayStart < end {
            if let window = hours.window(forDayStarting: dayStart, calendar: calendar) {
                let clipped = DateInterval(start: max(window.start, start), end: min(window.end, end))
                if clipped.start < clipped.end { windows.append(clipped) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = next
        }
        return windows
    }
}

extension AvailabilityResult {
    /// Free windows at least `length` seconds long, cut to start no earlier than `after`.
    public func freeWindows(atLeast length: TimeInterval, after: Date? = nil) -> [AvailabilityInterval] {
        free.compactMap { interval in
            let start = max(interval.start, after ?? interval.start)
            guard interval.end.timeIntervalSince(start) >= length else { return nil }
            return AvailabilityInterval(kind: .free, start: start, end: interval.end)
        }
    }
}
