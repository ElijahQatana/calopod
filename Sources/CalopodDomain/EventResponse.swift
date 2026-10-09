import Foundation

public enum EventResponseState: String, Codable, Sendable {
    case needsResponse = "needs-response"
    case accepted, tentative, declined, organizer
    case notApplicable = "not-applicable"
    case unknown
}

/// The calendar copy must be proven to represent the operator before using
/// owner-relative response fields. Edit permission alone is not that proof.
public enum ResponseIdentityScope: String, Codable, Sendable {
    case authenticatedUser = "authenticated-user"
    case unverified
}

public enum ResponseEvidence: String, Codable, Sendable {
    case googleSelf = "google-self"
    case microsoftEvent = "microsoft-event"
    case eventKitCurrentUser = "eventkit-current-user"
    case none
}

public enum ResponseLimit: String, Codable, Sendable {
    case identityUnverified = "identity-unverified"
    case missingParticipant = "missing-participant"
    case incompleteParticipants = "incomplete-participants"
    case ambiguousParticipant = "ambiguous-participant"
    case unsupportedStatus = "unsupported-status"
    case timestampUnavailable = "timestamp-unavailable"
    case readOnlyFeed = "read-only-feed"
    case legacyMetadata = "legacy-metadata"
}

public enum RSVPUnavailableReason: String, Codable, Sendable {
    case actionsNotImplemented = "actions-not-implemented"
    case identityUnverified = "identity-unverified"
    case notAnInvitation = "not-an-invitation"
    case unsupportedResponse = "unsupported-response"
    case providerReadOnly = "provider-read-only"
    case permissionUnverified = "permission-unverified"
    case unsupportedScope = "unsupported-scope"
    case staleRevision = "stale-revision"
    case managedMirror = "managed-mirror"
}

public enum RSVPActionScope: String, Codable, Sendable {
    case occurrence, series
}

/// Readable response evidence is separate from permission to send a response.
/// Action adapters establish permission and occurrence scope separately.
public struct RSVPActionCapability: Codable, Equatable, Sendable {
    public let isEligible: Bool
    public let supportedScopes: [RSVPActionScope]
    public let unavailableReasons: [RSVPUnavailableReason]

    /// Supplied only by a provider action implementation that establishes scope.
    public init(supportedScopes: [RSVPActionScope]) {
        isEligible = !supportedScopes.isEmpty
        self.supportedScopes = supportedScopes
        unavailableReasons = []
    }

    public init(unavailableReasons: [RSVPUnavailableReason]) {
        isEligible = false
        supportedScopes = []
        self.unavailableReasons = unavailableReasons
    }
}

public struct EventResponse: Codable, Equatable, Sendable {
    public let state: EventResponseState
    public let respondedAt: Date?
    public let evidence: ResponseEvidence
    public let limits: [ResponseLimit]
    public let actionCapability: RSVPActionCapability

    public init(
        state: EventResponseState,
        respondedAt: Date? = nil,
        evidence: ResponseEvidence = .none,
        limits: [ResponseLimit] = [],
        unavailableReasons: [RSVPUnavailableReason] = [.actionsNotImplemented],
        actionCapability: RSVPActionCapability? = nil
    ) {
        self.state = state
        self.respondedAt = respondedAt
        self.evidence = evidence
        self.limits = limits
        self.actionCapability = actionCapability ?? RSVPActionCapability(unavailableReasons: unavailableReasons)
    }

    public static let unavailable = EventResponse(
        state: .unknown, limits: [.legacyMetadata],
        unavailableReasons: [.identityUnverified, .actionsNotImplemented]
    )

    public static let readOnlyFeed = EventResponse(
        state: .unknown, limits: [.readOnlyFeed, .identityUnverified],
        unavailableReasons: [.providerReadOnly, .identityUnverified]
    )
}
