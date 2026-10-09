import CalopodDomain
import Foundation

public enum InboxActivityType: String, Codable, Sendable {
    case newEvent = "new-event"
    case contentChanged = "content-changed"
    case responseChanged = "response-changed"
    case cancelled, removed
}

public enum InboxResponseTiming: String, Codable, Sendable {
    case observedBaseline = "observed-baseline"
    case afterResponse = "after-response"
    case uncertain
    case notApplicable = "not-applicable"
}

/// A response baseline records what was actually observed, not a reconstructed
/// history of edits before Calopod first read an invitation.
public struct InboxResponseBaseline: Codable, Equatable, Sendable {
    public let event: StoredNormalizedInstance
    public let revision: Int64
    public let observedAt: Date
}

public struct InboxObservation: Codable, Equatable, Sendable {
    public let event: StoredNormalizedInstance
    public let revision: Int64
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let responseBaseline: InboxResponseBaseline?
    public let responseTiming: InboxResponseTiming
    public let tombstone: InboxActivityType?
    public let acknowledgedRevision: Int64?
}

/// Activity retains both intervals so moved events can be filtered once by
/// either their old or their new time. Tombstones retain the last known detail.
public struct InboxActivity: Codable, Equatable, Sendable {
    public let sourceKeyHash: String
    public let revision: Int64
    public let observedAt: Date
    public let types: [InboxActivityType]
    public let changedFields: [String]
    public let previousEvent: StoredNormalizedInstance?
    public let event: StoredNormalizedInstance
    public let responseTiming: InboxResponseTiming
    public let acknowledgedAt: Date?
}

extension StoredNormalizedInstance {
    /// Provider versions, attendee ordering, and other attendees' RSVP changes
    /// are deliberately absent from this comparison.
    func inboxChangedFields(from previous: Self) -> [String] {
        var fields: [String] = []
        if startsAt != previous.startsAt || endsAt != previous.endsAt { fields.append("time") }
        if isAllDay != previous.isAllDay { fields.append("all-day") }
        if title != previous.title { fields.append("title") }
        if location != previous.location { fields.append("location") }
        if notes != previous.notes { fields.append("notes") }
        if url != previous.url { fields.append("url") }
        if organizer?.name != previous.organizer?.name
            || organizer?.emailAddress != previous.organizer?.emailAddress { fields.append("organizer") }
        if isCancelled != previous.isCancelled { fields.append("cancellation") }
        return fields
    }

    var hasInboxResponseBaseline: Bool {
        [.accepted, .tentative, .declined].contains(currentUserResponse.state)
    }
}

/// Last complete read window; combine with Connection health to report freshness.
public struct InboxCoverage: Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let observedAt: Date

    public init(startsAt: Date, endsAt: Date, observedAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.observedAt = observedAt
    }
}
