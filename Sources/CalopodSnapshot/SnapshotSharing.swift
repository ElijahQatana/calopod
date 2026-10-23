import Foundation

public struct SnapshotParticipant: Equatable, Sendable, Identifiable {
    public enum Status: Sendable {
        case invited
        case accepted
    }

    public let id: String
    public let name: String
    public let status: Status

    public init(id: String, name: String, status: Status) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// Lets another Apple ID read a zone. The Mac app has the CloudKit one.
public protocol SnapshotSharing: Sendable {
    /// Returns the link the person opens. The zone must exist.
    func invite(email: String, inZone zone: String) async throws -> URL
    func participants(inZone zone: String) async throws -> [SnapshotParticipant]
    func remove(_ participant: SnapshotParticipant, inZone zone: String) async throws
    /// Ends the share for everyone. The zone and its records stay.
    func stopSharing(inZone zone: String) async throws
}

/// Keeps shares in memory, and can be told to fail, for tests.
public actor InMemorySnapshotSharing: SnapshotSharing {
    public struct Failure: Error, Equatable {
        public init() {}
    }

    public private(set) var people: [String: [SnapshotParticipant]] = [:]
    public var failure: Failure?

    public init() {}

    public func setFailing(_ failing: Bool) { failure = failing ? Failure() : nil }

    public func invite(email: String, inZone zone: String) throws -> URL {
        if let failure { throw failure }
        people[zone, default: []].append(SnapshotParticipant(id: email, name: email, status: .invited))
        return URL(string: "https://example.com/share/\(zone)")!
    }

    public func participants(inZone zone: String) throws -> [SnapshotParticipant] {
        if let failure { throw failure }
        return people[zone] ?? []
    }

    public func remove(_ participant: SnapshotParticipant, inZone zone: String) throws {
        if let failure { throw failure }
        people[zone]?.removeAll { $0.id == participant.id }
    }

    public func stopSharing(inZone zone: String) throws {
        if let failure { throw failure }
        people[zone] = nil
    }
}
