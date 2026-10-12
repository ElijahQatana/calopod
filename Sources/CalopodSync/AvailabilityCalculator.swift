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

/// Derives Busy and Free time across selected calendars. Only time ranges are used, so the result
/// is safe to share.
public enum AvailabilityCalculator {
    public static func calculate(
        instances: [StoredNormalizedInstance],
        from windowStart: Date,
        through windowEnd: Date
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

        // Free time is the gaps between the merged busy blocks.
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
