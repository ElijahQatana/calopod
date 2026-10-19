import CalopodDomain
import Foundation

public enum InboxReason: String, Codable, Sendable {
    case needsRSVP = "needs-response"
    case maybe
    case unreadChange = "changed-after-response"
    case conflict
}

/// Counts of replies from the people invited, so the phone never needs their addresses.
public struct AttendeeSummary: Codable, Equatable, Sendable {
    public let total: Int
    public let accepted: Int
    public let tentative: Int
    public let declined: Int

    public init(total: Int, accepted: Int = 0, tentative: Int = 0, declined: Int = 0) {
        self.total = total
        self.accepted = accepted
        self.tentative = tentative
        self.declined = declined
    }
}

/// Another event that overlaps an inbox item, as much as the phone shows of it.
public struct ConflictingEvent: Codable, Equatable, Sendable {
    public let title: String?
    public let startsAt: Date
    public let endsAt: Date

    public init(title: String?, startsAt: Date, endsAt: Date) {
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// One event as the Mac Inbox shows it. The id is the event's source key hash, not a provider id.
public struct InboxItem: SnapshotRecord {
    public let id: String
    public let reasons: [InboxReason]
    /// True when the order of the change and the reply could not be told.
    public let changeOrderUncertain: Bool
    public let title: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let timeZoneIdentifier: String?
    public let sourceName: String?
    public let calendarID: String
    public let response: EventResponseState
    public let organizerName: String?
    public let attendees: AttendeeSummary
    public let location: String?
    public let notes: String?
    public let url: String?
    public let conflicts: [ConflictingEvent]

    public init(
        id: String, reasons: [InboxReason], changeOrderUncertain: Bool = false, title: String?,
        startsAt: Date, endsAt: Date, isAllDay: Bool = false, timeZoneIdentifier: String? = nil,
        sourceName: String? = nil, calendarID: String, response: EventResponseState,
        organizerName: String? = nil, attendees: AttendeeSummary = AttendeeSummary(total: 0),
        location: String? = nil, notes: String? = nil, url: String? = nil,
        conflicts: [ConflictingEvent] = []
    ) {
        self.id = id
        self.reasons = reasons
        self.changeOrderUncertain = changeOrderUncertain
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.sourceName = sourceName
        self.calendarID = calendarID
        self.response = response
        self.organizerName = organizerName
        self.attendees = attendees
        self.location = location
        self.notes = notes
        self.url = url
        self.conflicts = conflicts
    }
}
