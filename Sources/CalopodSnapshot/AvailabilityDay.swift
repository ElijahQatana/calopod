import Foundation

public struct BusyInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Combined busy time for one local day. Free time is the gaps, so the phone works it out.
/// Only time ranges are here: no titles, calendars or people.
public struct AvailabilityDay: SnapshotRecord {
    /// The local day as `yyyy-MM-dd`, in `timeZoneIdentifier`.
    public let day: String
    public let timeZoneIdentifier: String
    public let busy: [BusyInterval]

    public var id: String { Self.recordID(day: day) }

    public init(day: String, timeZoneIdentifier: String, busy: [BusyInterval]) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.busy = busy
    }

    public static func recordID(day: String) -> String { "availability-\(day)" }

    private enum CodingKeys: String, CodingKey { case day, timeZoneIdentifier, busy }
}
