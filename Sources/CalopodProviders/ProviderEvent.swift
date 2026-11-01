import CalopodDomain
import Foundation

public enum ProviderAvailability: String, Codable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
}

/// Disappearance from a bounded provider view is not always deletion.
public enum ProviderTombstoneEvidence: String, Codable, Sendable {
    case cancelled, removed, unconfirmed
}

/// An event as a provider client reports it, before `EventNormalizer` reshapes it.
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
    /// Zone of an all-day event's dates, when the provider reports one.
    public let timeZoneIdentifier: String?
    public let availability: ProviderAvailability
    public let tombstoneEvidence: ProviderTombstoneEvidence?
    public let isCancelled: Bool
    public let isPrivate: Bool
    public let kind: EventKind?
    public let title: String?
    public let updatedAt: Date?
    public let isManagedMirror: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    public let organizer: EventParticipant?
    public let attendees: [EventParticipant]
    public let responseMetadata: EventResponse?
    /// A server-assigned id that stays the same when `eventID` changes after a sync.
    public let externalID: String?
    public var currentUserResponse: EventResponse {
        responseMetadata ?? (provider == "ics" ? .readOnlyFeed : .unavailable)
    }

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
        kind: EventKind? = nil,
        title: String?,
        updatedAt: Date?,
        isManagedMirror: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        organizer: EventParticipant? = nil,
        attendees: [EventParticipant] = [],
        responseMetadata: EventResponse? = nil,
        tombstoneEvidence: ProviderTombstoneEvidence? = nil,
        timeZoneIdentifier: String? = nil,
        externalID: String? = nil
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
        self.timeZoneIdentifier = timeZoneIdentifier
        self.availability = availability
        self.tombstoneEvidence = tombstoneEvidence
        self.isCancelled = isCancelled
        self.isPrivate = isPrivate
        self.kind = kind
        self.title = title
        self.updatedAt = updatedAt
        self.isManagedMirror = isManagedMirror
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
        self.responseMetadata = responseMetadata
        self.externalID = externalID
    }

    /// Marks this event as one of Calopod's mirrors so `EventNormalizer` leaves it out; otherwise a
    /// mirror could be read back as a source and loop.
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
            kind: kind,
            title: title,
            updatedAt: updatedAt,
            isManagedMirror: true,
            location: location,
            notes: notes,
            url: url,
            organizer: organizer,
            attendees: attendees,
            responseMetadata: responseMetadata,
            tombstoneEvidence: tombstoneEvidence,
            timeZoneIdentifier: timeZoneIdentifier,
            externalID: externalID
        )
    }
}

/// One page of events plus the state (`nextSyncToken`, `cursorUpdates`) to resume an incremental
/// fetch.
public struct ProviderEventPage: Codable, Equatable, Sendable {
    public let events: [ProviderEvent]
    /// Missing on older serialized reads, whose adapters already collected all pages.
    public let readIsComplete: Bool?
    public let nextSyncToken: String?
    public let refreshMode: ProviderRefreshMode
    public let cursorUpdates: [ProviderCursorUpdate]

    public init(
        events: [ProviderEvent],
        nextSyncToken: String?,
        refreshMode: ProviderRefreshMode = .full,
        cursorUpdates: [ProviderCursorUpdate] = [],
        readIsComplete: Bool = true
    ) {
        self.events = events
        self.readIsComplete = readIsComplete
        self.nextSyncToken = nextSyncToken
        self.refreshMode = refreshMode
        self.cursorUpdates = cursorUpdates
    }
}

/// Whether a page is the complete current state (`full`) or only changes (`incremental`).
/// `EventCache` needs this to know if absence means deletion.
public enum ProviderRefreshMode: String, Codable, Equatable, Sendable {
    case full
    case incremental
}

/// A provider's incremental cursor for one scope, saved so the next fetch can resume.
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
