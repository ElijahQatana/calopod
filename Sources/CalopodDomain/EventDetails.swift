import Foundation

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
