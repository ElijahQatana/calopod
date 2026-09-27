import Foundation

/// An organizer or attendee as reported by a provider. This is presentation
/// data only — Calopod never writes native attendees, so a participant
/// always ends up folded into safe fields like notes rather than a real
/// calendar invite.
public struct EventParticipant: Codable, Equatable, Sendable {
    public let name: String?
    public let emailAddress: String?
    public let status: String?

    public init(
        name: String? = nil,
        emailAddress: String? = nil,
        status: String? = nil
    ) {
        self.name = name
        self.emailAddress = emailAddress
        self.status = status
    }
}
