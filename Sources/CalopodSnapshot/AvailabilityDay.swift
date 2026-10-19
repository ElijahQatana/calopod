import Foundation

public struct BusyInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// How full a day is, with the same thresholds as the Mac's day dots.
public enum AvailabilityStatus: String, Codable, Equatable, Sendable {
    case mostlyFree
    case tight
    case overbooked
    case dayOff
}

/// One local day, already worked out on the Mac with the same calculation as the Mac app and
/// `calopod availability`. Only time ranges are here: no titles, calendars or people.
///
/// The fields after `busy` are optional. A feed from an older Mac leaves them out, and then the
/// phone only has the busy time. Ranges are real dates, not minutes after midnight, so a day with a
/// clock change needs no special case.
public struct AvailabilityDay: SnapshotRecord {
    /// The local day as `yyyy-MM-dd`, in `timeZoneIdentifier`.
    public let day: String
    public let timeZoneIdentifier: String
    /// Every busy block of the day, merged, including any outside working hours.
    public let busy: [BusyInterval]
    /// The working hours of this day, or nil on a day off or when the Mac did not send them.
    public let working: BusyInterval?
    /// The gaps inside `working`. Free time is the sum of these.
    public let free: [BusyInterval]?
    /// Events that start before an earlier event has ended.
    public let overlaps: Int?
    public let status: AvailabilityStatus?

    public var id: String { Self.recordID(day: day) }

    public init(
        day: String, timeZoneIdentifier: String, busy: [BusyInterval],
        working: BusyInterval? = nil, free: [BusyInterval]? = nil, overlaps: Int? = nil,
        status: AvailabilityStatus? = nil
    ) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.busy = busy
        self.working = working
        self.free = free
        self.overlaps = overlaps
        self.status = status
    }

    public static func recordID(day: String) -> String { "availability-\(day)" }

    private enum CodingKeys: String, CodingKey { case day, timeZoneIdentifier, busy, working, free, overlaps, status }
}
