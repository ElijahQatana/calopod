import CalopodProviders
import Foundation

/// The Calendar-access permission state as reported by the EventKit host
/// process. `writeOnly` and `notDetermined` both need user action before
/// sync can proceed; only `fullAccess` allows reading event content.
public enum EventKitAccessStatus: String, Codable, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case fullAccess = "full-access"
    case writeOnly = "write-only"
    case unknown
}

/// One EventKit calendar as reported by the host process, including its
/// source (account) metadata — used both for display and for
/// `EventKitSourceClassifier`'s direct-provider duplicate detection.
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

/// One request Calopod can send to the separate EventKit host process. The
/// host runs out-of-process because it's the process macOS actually grants
/// (or denies) Calendar access to.
public enum EventKitHostOperation: String, Codable, Sendable {
    case permissionStatus
    case calendars
    case events
    case managedEvents
    case createManagedEvent
    case updateManagedEvent
    case deleteManagedEvent
}

/// Wire format for one call to the EventKit host: which operation, and
/// whichever of the operation-specific fields it needs (unused fields are
/// simply left nil for a given operation).
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

/// Wire format for the EventKit host's reply. `status` is always populated,
/// even on failure, so a caller can distinguish a permission problem from an
/// operation-specific error captured in `errorCode`.
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
