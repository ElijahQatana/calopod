import Foundation

public enum ProviderAvailability: String, Codable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
}

public struct ProviderEvent: Equatable, Sendable {
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
        updatedAt: Date?
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
    }
}

public struct ProviderEventPage: Equatable, Sendable {
    public let events: [ProviderEvent]
    public let nextSyncToken: String?

    public init(events: [ProviderEvent], nextSyncToken: String?) {
        self.events = events
        self.nextSyncToken = nextSyncToken
    }
}
