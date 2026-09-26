import CalopodDomain
import Foundation

public enum ProviderAvailability: String, Codable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
}

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

public enum ProviderRefreshMode: String, Codable, Equatable, Sendable {
    case full
    case incremental
}

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
