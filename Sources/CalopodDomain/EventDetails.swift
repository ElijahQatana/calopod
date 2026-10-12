import Foundation

/// An organizer or attendee as reported by a provider. Display only: Calopod writes people into
/// notes, never as real attendees.
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
