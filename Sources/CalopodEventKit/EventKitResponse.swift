import CalopodDomain
import EventKit

/// A small value snapshot allows response normalization without opening a store.
public struct EventKitResponseParticipant: Equatable, Sendable {
    public let isCurrentUser: Bool
    public let status: EKParticipantStatus

    public init(isCurrentUser: Bool, status: EKParticipantStatus) {
        self.isCurrentUser = isCurrentUser
        self.status = status
    }
}

public enum EventKitResponseNormalizer {
    public static func response(
        organizerIsCurrentUser: Bool,
        participants: [EventKitResponseParticipant],
        sourceType: String
    ) -> EventResponse {
        if organizerIsCurrentUser {
            return EventResponse(state: .organizer, evidence: .eventKitCurrentUser,
                                 limits: [.timestampUnavailable],
                                 unavailableReasons: [.providerReadOnly, .notAnInvitation])
        }
        let current = participants.filter(\.isCurrentUser)
        guard current.count == 1 else {
            if current.isEmpty, participants.isEmpty, sourceType == "birthdays" {
                return EventResponse(state: .notApplicable, limits: [.timestampUnavailable],
                                     unavailableReasons: [.providerReadOnly, .notAnInvitation])
            }
            return EventResponse(state: .unknown,
                                 limits: [current.isEmpty ? .missingParticipant : .ambiguousParticipant,
                                          .timestampUnavailable],
                                 unavailableReasons: [.providerReadOnly, .identityUnverified])
        }
        let state: EventResponseState
        switch current[0].status {
        case .pending: state = .needsResponse
        case .accepted: state = .accepted
        case .tentative: state = .tentative
        case .declined: state = .declined
        default: state = .unknown
        }
        return EventResponse(state: state, evidence: .eventKitCurrentUser,
                             limits: state == .unknown ? [.unsupportedStatus, .timestampUnavailable]
                                 : [.timestampUnavailable],
                             unavailableReasons: [.providerReadOnly])
    }
}
