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

    public init(busy: [AvailabilityInterval], free: [AvailabilityInterval]) {
        self.busy = busy
        self.free = free
    }
}

/// Derives Busy/Free Availability across every selected source calendar for
/// a window. This only reasons about time ranges — no titles, locations, or
/// other event content ever passes through here, which keeps Availability
/// safe to share even when the underlying events are private.
public enum AvailabilityCalculator {
    public static func calculate(
        instances: [StoredNormalizedInstance],
        from windowStart: Date,
        through windowEnd: Date
    ) -> AvailabilityResult {
        guard windowStart < windowEnd else {
            return AvailabilityResult(busy: [], free: [])
        }

        // Clip every busy source interval to the requested window up front,
        // so the merge pass below never has to special-case a range that
        // extends outside it.
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

        // Sweep the sorted, clipped intervals left to right and merge any
        // that touch or overlap. This collapses events from multiple
        // overlapping calendars into one Busy block instead of reporting
        // each source separately.
        var busy: [AvailabilityInterval] = []
        for candidate in candidates {
            guard let current = busy.last else {
                busy.append(candidate)
                continue
            }
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

        // Free time is simply whatever the merged Busy blocks don't cover,
        // walked as the gaps between them (and before the first / after the
        // last) within the window.
        var free: [AvailabilityInterval] = []
        var cursor = windowStart
        for interval in busy {
            if cursor < interval.start {
                free.append(
                    AvailabilityInterval(kind: .free, start: cursor, end: interval.start)
                )
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < windowEnd {
            free.append(AvailabilityInterval(kind: .free, start: cursor, end: windowEnd))
        }

        return AvailabilityResult(busy: busy, free: free)
    }
}
