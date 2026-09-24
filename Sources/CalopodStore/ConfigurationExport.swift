import CalopodDomain
import Foundation

public struct ExportedConfiguration: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let configurationID: UUID
    public let connections: [ExportedConnection]
    public let calendarBindings: [ExportedCalendarBinding]
    public let arms: [ExportedArm]

    public init(
        configurationID: UUID,
        connections: [ExportedConnection],
        calendarBindings: [ExportedCalendarBinding],
        arms: [ExportedArm]
    ) {
        formatVersion = 1
        self.configurationID = configurationID
        self.connections = connections
        self.calendarBindings = calendarBindings
        self.arms = arms
    }
}

public struct ExportedConnection: Codable, Equatable, Sendable {
    public let id: UUID
    public let provider: ProviderKind

    public init(id: UUID, provider: ProviderKind) {
        self.id = id
        self.provider = provider
    }
}

public struct ExportedCalendarBinding: Codable, Equatable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let isSelected: Bool
    public let requiresRebinding: Bool

    public init(id: UUID, connectionID: UUID, isSelected: Bool) {
        self.id = id
        self.connectionID = connectionID
        self.isSelected = isSelected
        requiresRebinding = true
    }
}

public struct ExportedArm: Codable, Equatable, Sendable {
    public enum RuleMode: String, Codable, Sendable {
        case busy
        case fullDetails = "full-details"
    }

    public let id: UUID
    public let sourceBindingIDs: [UUID]
    public let targetBindingID: UUID
    public let ruleMode: RuleMode
    public let preferredWriterDeviceID: UUID?

    public init(
        id: UUID,
        sourceBindingIDs: [UUID],
        targetBindingID: UUID,
        ruleMode: RuleMode,
        preferredWriterDeviceID: UUID?
    ) {
        self.id = id
        self.sourceBindingIDs = sourceBindingIDs
        self.targetBindingID = targetBindingID
        self.ruleMode = ruleMode
        self.preferredWriterDeviceID = preferredWriterDeviceID
    }
}
