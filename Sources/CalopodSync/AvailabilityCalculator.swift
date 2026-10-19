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

public struct AvailabilityResult: Equatable, Sendable {
    public let busy: [AvailabilityInterval]
    public let free: [AvailabilityInterval]
    /// The working windows inside the range, or nil when working hours were not applied.
    public let workingWindows: [DateInterval]?
    /// Events that start before an earlier event has ended.
    public let overlaps: Int

    public init(
        busy: [AvailabilityInterval], free: [AvailabilityInterval],
        workingWindows: [DateInterval]? = nil, overlaps: Int = 0
    ) {
        self.busy = busy
        self.free = free
        self.workingWindows = workingWindows
        self.overlaps = overlaps
    }
}

/// Derives Busy and Free time across selected calendars. Only time ranges are used, so the result
/// is safe to share. With working hours, only time inside them counts as free; busy time outside
/// them is still reported.
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
        var busy: [AvailabilityInterval] = []
        var overlaps = 0
        for candidate in candidates {
            guard let current = busy.last else {
                busy.append(candidate)
                continue
            }
            if candidate.start < current.end { overlaps += 1 }
            if candidate.start <= current.end {
                busy[busy.count - 1] = AvailabilityInterval(
                    kind: .busy,
                    start: current.start,
                    end: max(current.end, candidate.end)
                )
            } else {
                busy.append(candidate)
            }
        }

        // Free time is the gaps between the merged busy blocks, inside working hours if given.
        let windows = workingHours.map {
            workingWindows($0, from: windowStart, through: windowEnd, timeZone: timeZone)
        }
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

        return AvailabilityResult(busy: busy, free: free, workingWindows: windows, overlaps: overlaps)
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
