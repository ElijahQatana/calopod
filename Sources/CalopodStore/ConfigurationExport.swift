import CalopodDomain
import Foundation

/// Portable snapshot of a configuration's Connections, calendar bindings,
/// and Arms — used to move setup between devices or restore it, without
/// carrying any cached event content or secrets along with it.
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

/// A Connection's identity and provider kind, without any credentials —
/// tokens and keys live in Keychain and are never part of an export.
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
    // Always true on export: a calendar binding's provider-side identifier
    // may not resolve on the importing device (a different Mac's EventKit
    // store, for instance), so import always re-resolves it deliberately
    // rather than trusting the exported ID.
    public let requiresRebinding: Bool

    public init(id: UUID, connectionID: UUID, isSelected: Bool) {
        self.id = id
        self.connectionID = connectionID
        self.isSelected = isSelected
        requiresRebinding = true
    }
}

/// An Arm's routing and Rule, referencing calendar bindings by the same IDs
/// as `ExportedCalendarBinding` so the two reassemble correctly on import.
public struct ExportedArm: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceBindingIDs: [UUID]
    public let targetBindingID: UUID
    public let ruleMode: ArmRuleMode
    public let preferredWriterDeviceID: UUID?

    public init(
        id: UUID,
        sourceBindingIDs: [UUID],
        targetBindingID: UUID,
        ruleMode: ArmRuleMode,
        preferredWriterDeviceID: UUID?
    ) {
        self.id = id
        self.sourceBindingIDs = sourceBindingIDs
        self.targetBindingID = targetBindingID
        self.ruleMode = ruleMode
        self.preferredWriterDeviceID = preferredWriterDeviceID
    }
}
