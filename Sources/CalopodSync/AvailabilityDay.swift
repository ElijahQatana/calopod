import Foundation

/// How full a day is, for the dot in the day strip.
public enum AvailabilityLoad: String, Equatable, Sendable {
    case dayOff
    case mostlyFree
    case tight
    case overbooked
}

/// Free and busy totals for one day of an availability result.
public struct AvailabilityDay: Equatable, Sendable {
    public let freeSeconds: TimeInterval
    /// Every busy block, including those outside working hours.
    public let busySeconds: TimeInterval
    public let overlaps: Int
    public let load: AvailabilityLoad

    /// `day` is the range the result was calculated for. Without working hours the whole range
    /// counts as working time.
    public init(_ result: AvailabilityResult, day: DateInterval) {
        let working = result.workingWindows ?? [day]
        let workingSeconds = working.reduce(0) { $0 + $1.duration }
        freeSeconds = result.free.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        busySeconds = result.busy.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        overlaps = result.overlaps
        if workingSeconds == 0 {
            load = .dayOff
        } else if freeSeconds >= workingSeconds / 2 {
            load = .mostlyFree
        } else if freeSeconds >= workingSeconds * 0.15 {
            load = .tight
        } else {
            load = .overbooked
        }
    }
}
