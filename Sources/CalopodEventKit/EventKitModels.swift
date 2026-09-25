import CalopodProviders
import Foundation

public enum EventKitAccessStatus: String, Codable, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case fullAccess = "full-access"
    case writeOnly = "write-only"
    case unknown
}

public struct EventKitCalendarSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let sourceTitle: String
    public let sourceType: String
    public let allowsContentModifications: Bool

    public init(
        id: String,
        title: String,
        sourceID: String,
        sourceTitle: String,
        sourceType: String,
        allowsContentModifications: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
        self.allowsContentModifications = allowsContentModifications
    }
}

public enum EventKitHostOperation: String, Codable, Sendable {
    case permissionStatus
    case calendars
    case events
    case managedEvents
    case createManagedEvent
    case updateManagedEvent
    case deleteManagedEvent
}

public struct EventKitHostRequest: Codable, Sendable {
    public let operation: EventKitHostOperation
    public let calendarIDs: [String]
    public let start: Date?
    public let end: Date?
    public let managedEvent: ManagedEventWriteRequest?
    public let providerEventID: String?
    public let expectedProviderVersion: String?

    public init(
        operation: EventKitHostOperation,
        calendarIDs: [String] = [],
        start: Date? = nil,
        end: Date? = nil,
        managedEvent: ManagedEventWriteRequest? = nil,
        providerEventID: String? = nil,
        expectedProviderVersion: String? = nil
    ) {
        self.operation = operation
        self.calendarIDs = calendarIDs
        self.start = start
        self.end = end
        self.managedEvent = managedEvent
        self.providerEventID = providerEventID
        self.expectedProviderVersion = expectedProviderVersion
    }
}

public struct EventKitHostResponse: Codable, Sendable {
    public let status: EventKitAccessStatus
    public let calendars: [EventKitCalendarSnapshot]
    public let events: [ProviderEvent]
    public let managedEvents: [ManagedEventSnapshot]
    public let managedEvent: ManagedEventWriteResult?
    public let errorCode: String?

    public init(
        status: EventKitAccessStatus,
        calendars: [EventKitCalendarSnapshot] = [],
        events: [ProviderEvent] = [],
        managedEvents: [ManagedEventSnapshot] = [],
        managedEvent: ManagedEventWriteResult? = nil,
        errorCode: String? = nil
    ) {
        self.status = status
        self.calendars = calendars
        self.events = events
        self.managedEvents = managedEvents
        self.managedEvent = managedEvent
        self.errorCode = errorCode
    }
}
