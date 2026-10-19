import CalopodProviders
import Foundation

/// Calendar permission as reported by the host. Only `fullAccess` lets Calopod read event content.
public enum EventKitAccessStatus: String, Codable, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case fullAccess = "full-access"
    case writeOnly = "write-only"
    case unknown
}

/// How a request for Calendar access ended, as far as the person is concerned.
public enum CalendarAccessOutcome: String, Codable, Equatable, Sendable {
    case granted
    case denied
    /// The request returned and macOS still has no decision, so it never showed the prompt.
    case undecided
    /// The helper could not run or could not ask.
    case couldNotStart

    /// The outcome for the status read right after a request.
    public init(statusAfterRequest status: EventKitAccessStatus) {
        switch status {
        case .fullAccess: self = .granted
        case .notDetermined: self = .undecided
        case .denied, .restricted, .writeOnly, .unknown: self = .denied
        }
    }
}

/// One calendar as reported by the host, with its account metadata for duplicate-source detection.
public struct EventKitCalendarSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let sourceTitle: String
    public let sourceType: String
    public let allowsContentModifications: Bool
    /// The Calendar app color as `#rrggbb`, when the host could read it.
    public let color: String?

    public init(
        id: String,
        title: String,
        sourceID: String,
        sourceTitle: String,
        sourceType: String,
        allowsContentModifications: Bool,
        color: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
        self.allowsContentModifications = allowsContentModifications
        self.color = color
    }
}

/// A request Calopod can send to the host. The host is a separate process because macOS grants
/// Calendar access per app.
public enum EventKitHostOperation: String, Codable, Sendable {
    case batch
    case permissionStatus
    case calendars
    case events
    case managedEvents
    case createManagedEvent
    case updateManagedEvent
    case deleteManagedEvent
}

/// Wire format for a host call: the operation plus whichever fields it needs.
public struct EventKitHostRequest: Codable, Sendable {
    public let protocolVersion: Int?
    public let batches: [[EventKitHostRequest]]?
    public let operation: EventKitHostOperation
    public let calendarIDs: [String]
    public let start: Date?
    public let end: Date?
    public let managedEvent: ManagedEventWriteRequest?
    public let providerEventID: String?
    public let expectedProviderVersion: String?

    public init(
        operation: EventKitHostOperation,
        protocolVersion: Int? = nil,
        batches: [[EventKitHostRequest]]? = nil,
        calendarIDs: [String] = [],
        start: Date? = nil,
        end: Date? = nil,
        managedEvent: ManagedEventWriteRequest? = nil,
        providerEventID: String? = nil,
        expectedProviderVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.batches = batches
        self.operation = operation
        self.calendarIDs = calendarIDs
        self.start = start
        self.end = end
        self.managedEvent = managedEvent
        self.providerEventID = providerEventID
        self.expectedProviderVersion = expectedProviderVersion
    }
}

/// Wire format for the host's reply. `status` is always set so a permission problem can be told
/// apart from an operation error.
public struct EventKitHostResponse: Codable, Sendable {
    public let protocolVersion: Int?
    public let batches: [[EventKitHostResponse]]?
    public let status: EventKitAccessStatus
    public let calendars: [EventKitCalendarSnapshot]
    public let events: [ProviderEvent]
    public let managedEvents: [ManagedEventSnapshot]
    public let managedEvent: ManagedEventWriteResult?
    public let errorCode: String?
    /// Set only by the permission request.
    public let requestOutcome: CalendarAccessOutcome?

    public init(
        status: EventKitAccessStatus,
        protocolVersion: Int? = nil,
        batches: [[EventKitHostResponse]]? = nil,
        calendars: [EventKitCalendarSnapshot] = [],
        events: [ProviderEvent] = [],
        managedEvents: [ManagedEventSnapshot] = [],
        managedEvent: ManagedEventWriteResult? = nil,
        errorCode: String? = nil,
        requestOutcome: CalendarAccessOutcome? = nil
    ) {
        self.requestOutcome = requestOutcome
        self.protocolVersion = protocolVersion
        self.batches = batches
        self.status = status
        self.calendars = calendars
        self.events = events
        self.managedEvents = managedEvents
        self.managedEvent = managedEvent
        self.errorCode = errorCode
    }
}
