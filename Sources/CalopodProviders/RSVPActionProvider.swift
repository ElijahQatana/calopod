import CalopodDomain
import CalopodStore
import Foundation

public struct RSVPAuthorization: Sendable {
    public let identityScope: ResponseIdentityScope
    public let canRespond: Bool

    public init(identityScope: ResponseIdentityScope, canRespond: Bool) {
        self.identityScope = identityScope
        self.canRespond = canRespond
    }
}

public struct RSVPEventSnapshot: Sendable {
    public let target: RSVPTarget
    public let event: ProviderEvent
    public let version: String?
    public let capability: RSVPActionCapability
    public let notification: RSVPNotificationPolicy
    public let concurrency: RSVPConcurrency
    public let currentUserEmail: String?

    public init(target: RSVPTarget, event: ProviderEvent, version: String?, capability: RSVPActionCapability,
                notification: RSVPNotificationPolicy, concurrency: RSVPConcurrency, currentUserEmail: String? = nil) {
        self.target = target
        self.event = event
        self.version = version
        self.capability = capability
        self.notification = notification
        self.concurrency = concurrency
        self.currentUserEmail = currentUserEmail
    }

    public func validate(_ intent: RSVPActionIntent) throws {
        guard target == intent.target else { throw RSVPActionError.unavailable(.identity) }
        guard capability.isEligible else {
            let reasons = capability.unavailableReasons
            let issue: RSVPActionIssue = reasons.contains(.identityUnverified) ? .identity
                : reasons.contains(.permissionUnverified) ? .permission
                : reasons.contains(.managedMirror) ? .managedMirror
                : reasons.contains(.unsupportedScope) ? .scope : .unsupported
            throw RSVPActionError.unavailable(issue)
        }
        guard let version, !version.isEmpty, version == intent.expectedVersion,
              event.currentUserResponse.state == intent.previousResponse else { throw RSVPActionError.stale }
    }
}

public enum RSVPActionError: Error, Equatable, Sendable {
    case stale
    case unavailable(RSVPActionIssue)
    case rejected
    case uncertain

    public var outcome: RSVPActionOutcome {
        switch self {
        case .stale: RSVPActionOutcome(status: .stale, issue: .revision)
        case .unavailable(let issue): RSVPActionOutcome(status: .unavailable, issue: issue)
        case .rejected: RSVPActionOutcome(status: .failed, issue: .providerRejected)
        case .uncertain: RSVPActionOutcome(status: .unknown, issue: .uncertain)
        }
    }

    public static func preflightFailure(_ error: Error) -> RSVPActionError {
        if let actionError = error as? RSVPActionError { return actionError }
        let mapped = writeFailure(error)
        return mapped == .uncertain ? .rejected : mapped
    }

    public static func writeFailure(_ error: Error) -> RSVPActionError {
        switch error {
        case ProviderFailure.httpStatus(412): .stale
        case ProviderFailure.authorizationRequired, ProviderFailure.permissionDenied,
             ProviderFailure.accountPolicyRequired, ProviderFailure.httpStatus(403): .unavailable(.permission)
        case ProviderFailure.httpStatus(let code) where (400..<500).contains(code) && code != 408: .rejected
        default: .uncertain
        }
    }
}

public protocol RSVPActionProvider: Sendable {
    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot
    /// Revalidate, then submit once. A return means the provider accepted the request.
    func submitRSVP(_ intent: RSVPActionIntent) async throws
    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome
}

/// Call only for an explicit user decision. Recovery never submits another request.
public struct RSVPActionExecutor: Sendable {
    private let state: LocalStateRepository

    public init(state: LocalStateRepository) { self.state = state }

    public func perform(_ intent: RSVPActionIntent, using provider: any RSVPActionProvider) async throws -> RSVPActionRecord {
        // An existing ID is recovery, even if a crash left it in pending state.
        if let existing = try state.rsvpAction(id: intent.id) {
            guard existing.intent == intent else { throw RSVPActionStoreError.intentMismatch }
            return try await reconcile(existing, using: provider)
        }
        let reservation = try state.beginRSVPAction(intent)
        let record = reservation.record
        guard reservation.isNew else { return try await reconcile(record, using: provider) }
        do {
            try Task.checkCancellation()
            try await provider.submitRSVP(record.intent)
        } catch {
            let outcome = (error as? RSVPActionError)?.outcome ?? RSVPActionOutcome(status: .unknown, issue: .uncertain)
            return try state.saveRSVPOutcome(id: intent.id, outcome: outcome)
        }
        let accepted = try state.saveRSVPOutcome(id: intent.id, outcome: RSVPActionOutcome(status: .accepted))
        return try await reconcile(accepted, using: provider)
    }

    public func reconcile(_ record: RSVPActionRecord, using provider: any RSVPActionProvider) async throws -> RSVPActionRecord {
        guard record.outcome.status.isUnresolved else { return record }
        let outcome: RSVPActionOutcome
        do { outcome = try await provider.reconcileRSVP(record) }
        catch { outcome = RSVPActionOutcome(status: .unknown, issue: .uncertain) }
        return try state.saveRSVPOutcome(id: record.intent.id, outcome: outcome)
    }
}

public enum RSVPReadback {
    public static func outcome(_ record: RSVPActionRecord, snapshot: RSVPEventSnapshot) -> RSVPActionOutcome {
        let intent = record.intent
        guard snapshot.target == intent.target, snapshot.capability.isEligible else {
            return RSVPActionOutcome(status: .unknown, issue: .identity)
        }
        // A pre-existing matching response is not evidence a lost request completed.
        guard snapshot.event.currentUserResponse.state == intent.decision.responseState,
              record.submissionAccepted || intent.previousResponse != intent.decision.responseState else {
            return RSVPActionOutcome(status: .unknown, issue: .uncertain)
        }
        return RSVPActionOutcome(status: .confirmed, confirmedResponse: intent.decision.responseState)
    }

    public static func missing(_ record: RSVPActionRecord) -> RSVPActionOutcome {
        if record.intent.decision == .no && record.submissionAccepted {
            return RSVPActionOutcome(status: .confirmed, confirmedResponse: .declined, disappearedAfterDecline: true)
        }
        return RSVPActionOutcome(status: .unknown, issue: .uncertain)
    }
}

extension LocalStateRepository {
    public func rsvpBinding(target: RSVPTarget, provider: String) throws -> StoredCalendarBinding {
        guard target.provider == provider,
              let connection = try connection(id: target.connectionID), connection.provider == provider, connection.isEnabled,
              let binding = try calendarBinding(id: target.calendarBindingID), binding.isSelected,
              binding.connectionID == target.connectionID, binding.providerCalendarID == target.calendarID else {
            throw RSVPActionError.unavailable(.identity)
        }
        guard binding.responseIdentityScope == .authenticatedUser else { throw RSVPActionError.unavailable(.identity) }
        guard !binding.isReadOnly else { throw RSVPActionError.unavailable(.permission) }
        guard try !isMappedRSVPTarget(target) else { throw RSVPActionError.unavailable(.managedMirror) }
        return binding
    }
}
