import CalopodDomain
import Foundation

/// One event on a chosen calendar. A private event arrives without its title and location. There are
/// no notes or people. The meeting link is only sent for an event that can get a reminder.
public struct CalendarEvent: Codable, Equatable, Sendable {
    /// The event's source key hash, stable across publishes.
    public let id: String
    public let calendarID: String
    public let title: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let location: String?
    public let response: EventResponseState
    /// The Teams, Zoom, Meet or Webex link, for the Join button on a reminder.
    public let joinURL: String?

    public init(
        id: String, calendarID: String, title: String?, startsAt: Date, endsAt: Date,
        isAllDay: Bool = false, location: String? = nil, response: EventResponseState,
        joinURL: String? = nil
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.location = location
        self.response = response
        self.joinURL = joinURL
    }
}

/// The events of every chosen calendar that touch one local day. One record per day keeps each under
/// CloudKit's size limit. A day with no events has no record.
public struct CalendarDay: SnapshotRecord {
    /// The local day as `yyyy-MM-dd`, in `timeZoneIdentifier`.
    public let day: String
    public let timeZoneIdentifier: String
    public let events: [CalendarEvent]

    public var id: String { Self.recordID(day: day) }

    public init(day: String, timeZoneIdentifier: String, events: [CalendarEvent]) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.events = events
    }

    public static func recordID(day: String) -> String { "calendar-day-\(day)" }

    private enum CodingKeys: String, CodingKey { case day, timeZoneIdentifier, events }
}
