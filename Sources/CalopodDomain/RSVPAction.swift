import Foundation

public enum RSVPDecision: String, Codable, Sendable {
    case yes, no, maybe

    public var responseState: EventResponseState {
        switch self {
        case .yes: .accepted
        case .no: .declined
        case .maybe: .tentative
        }
    }
}

/// Exact source identity; no account or backend substitution is allowed.
public struct RSVPTarget: Codable, Equatable, Sendable {
    public let provider: String
    public let connectionID: String
    public let calendarBindingID: String
    public let calendarID: String
    public let eventID: String
    public let seriesID: String?
    public let originalStart: String?

    public init(provider: String, connectionID: String, calendarBindingID: String,
                calendarID: String, eventID: String, seriesID: String? = nil, originalStart: String? = nil) {
        self.provider = provider
        self.connectionID = connectionID
        self.calendarBindingID = calendarBindingID
        self.calendarID = calendarID
        self.eventID = eventID
        self.seriesID = seriesID
        self.originalStart = originalStart
    }
}

public enum RSVPNotificationPolicy: String, Codable, Sendable {
    case googleAllGuests = "google-all-guests"
    case microsoftOrganizer = "microsoft-organizer"
}

public enum RSVPConcurrency: String, Codable, Sendable {
    case conditionalUpdate = "conditional-update"
    case preflightOnly = "preflight-only"
}

/// Construct a decision only after presenting this exact provider revision.
public struct RSVPActionIntent: Codable, Equatable, Sendable {
    public let id: String
    public let target: RSVPTarget
    public let expectedVersion: String
    public let previousResponse: EventResponseState
    public let decision: RSVPDecision

    public init(id: String = UUID().uuidString.lowercased(), target: RSVPTarget,
                expectedVersion: String, previousResponse: EventResponseState, decision: RSVPDecision) {
        self.id = id
        self.target = target
        self.expectedVersion = expectedVersion
        self.previousResponse = previousResponse
        self.decision = decision
    }
}

public enum RSVPActionStatus: String, Codable, Sendable {
    case pending, accepted, confirmed, failed, unknown, stale, unavailable

    public var isUnresolved: Bool { self == .pending || self == .accepted || self == .unknown }
}

public enum RSVPActionIssue: String, Codable, Sendable {
    case identity, permission, unsupported, scope, managedMirror = "managed-mirror"
    case revision, providerRejected = "provider-rejected", uncertain
}

public struct RSVPActionOutcome: Codable, Equatable, Sendable {
    public let status: RSVPActionStatus
    public let issue: RSVPActionIssue?
    public let confirmedResponse: EventResponseState?
    public let disappearedAfterDecline: Bool

    public init(status: RSVPActionStatus, issue: RSVPActionIssue? = nil,
                confirmedResponse: EventResponseState? = nil, disappearedAfterDecline: Bool = false) {
        self.status = status
        self.issue = issue
        self.confirmedResponse = confirmedResponse
        self.disappearedAfterDecline = disappearedAfterDecline
    }
}

public struct RSVPActionRecord: Codable, Equatable, Sendable {
    public let intent: RSVPActionIntent
    public let outcome: RSVPActionOutcome
    public let submissionAccepted: Bool

    public init(intent: RSVPActionIntent, outcome: RSVPActionOutcome, submissionAccepted: Bool = false) {
        self.intent = intent
        self.outcome = outcome
        self.submissionAccepted = submissionAccepted || outcome.status == .accepted
    }
}
