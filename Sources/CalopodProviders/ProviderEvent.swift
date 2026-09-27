import CalopodDomain
import Foundation

public enum ProviderAvailability: String, Codable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
}

/// A calendar event exactly as one provider client reports it, before
/// `EventNormalizer` reshapes it into a `StoredNormalizedInstance`. Provider
/// clients translate into this common shape so nothing downstream needs to
/// know which backend an event came from.
public struct ProviderEvent: Codable, Equatable, Sendable {
    public let provider: String
    public let connectionID: String
    public let calendarID: String
    public let eventID: String
    public let seriesID: String?
    public let originalStart: String?
    public let start: Date?
    public let end: Date?
    public let isAllDay: Bool
    public let availability: ProviderAvailability
    public let isCancelled: Bool
    public let isPrivate: Bool
    public let title: String?
    public let updatedAt: Date?
    public let isManagedMirror: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    public let organizer: EventParticipant?
    public let attendees: [EventParticipant]

    public init(
        provider: String,
        connectionID: String,
        calendarID: String,
        eventID: String,
        seriesID: String?,
        originalStart: String?,
        start: Date?,
        end: Date?,
        isAllDay: Bool,
        availability: ProviderAvailability,
        isCancelled: Bool,
        isPrivate: Bool,
        title: String?,
        updatedAt: Date?,
        isManagedMirror: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        organizer: EventParticipant? = nil,
        attendees: [EventParticipant] = []
    ) {
        self.provider = provider
        self.connectionID = connectionID
        self.calendarID = calendarID
        self.eventID = eventID
        self.seriesID = seriesID
        self.originalStart = originalStart
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.availability = availability
        self.isCancelled = isCancelled
        self.isPrivate = isPrivate
        self.title = title
        self.updatedAt = updatedAt
        self.isManagedMirror = isManagedMirror
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
    }

    /// Tags this event as one of Calopod's own managed mirrors so
    /// `EventNormalizer` excludes it from source ingestion — without this,
    /// a mirror could be read back in as a new source event and sync itself
    /// in a loop.
    public func markingManagedMirror() -> ProviderEvent {
        ProviderEvent(
            provider: provider,
            connectionID: connectionID,
            calendarID: calendarID,
            eventID: eventID,
            seriesID: seriesID,
            originalStart: originalStart,
            start: start,
            end: end,
            isAllDay: isAllDay,
            availability: availability,
            isCancelled: isCancelled,
            isPrivate: isPrivate,
            title: title,
            updatedAt: updatedAt,
            isManagedMirror: true,
            location: location,
            notes: notes,
            url: url,
            organizer: organizer,
            attendees: attendees
        )
    }
}

/// One page of events returned from a provider fetch, plus enough state
/// (`nextSyncToken`, `cursorUpdates`) to resume an incremental fetch next
/// time without re-scanning the whole calendar.
public struct ProviderEventPage: Codable, Equatable, Sendable {
    public let events: [ProviderEvent]
    public let nextSyncToken: String?
    public let refreshMode: ProviderRefreshMode
    public let cursorUpdates: [ProviderCursorUpdate]

    public init(
        events: [ProviderEvent],
        nextSyncToken: String?,
        refreshMode: ProviderRefreshMode = .full,
        cursorUpdates: [ProviderCursorUpdate] = []
    ) {
        self.events = events
        self.nextSyncToken = nextSyncToken
        self.refreshMode = refreshMode
        self.cursorUpdates = cursorUpdates
    }
}

/// Whether a fetched page represents the complete current state of a
/// calendar (`full`) or only the events that changed since the last cursor
/// (`incremental`). `EventCache` needs this to know whether an event's
/// absence from a page means it was deleted.
public enum ProviderRefreshMode: String, Codable, Equatable, Sendable {
    case full
    case incremental
}

/// A provider's incremental-sync cursor for one scope (a calendar, or a
/// bounded window within one), persisted so the next fetch can resume from
/// here instead of re-reading everything.
public struct ProviderCursorUpdate: Codable, Equatable, Sendable {
    public let scopeKey: String
    public let value: String
    public let scopeStart: Date?
    public let scopeEnd: Date?

    public init(
        scopeKey: String,
        value: String,
        scopeStart: Date? = nil,
        scopeEnd: Date? = nil
    ) {
        self.scopeKey = scopeKey
        self.value = value
        self.scopeStart = scopeStart
        self.scopeEnd = scopeEnd
    }
}
