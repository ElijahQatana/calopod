#if os(macOS)
import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation

public enum SetupProvider: String, CaseIterable, Sendable {
    case mac
    case google
    case microsoft
}

public struct SetupCalendar: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceLabel: String?
    public let isSelected: Bool
    public let isReadOnly: Bool
    public let providerColor: String?
}

public struct SetupConnection: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let label: String
    public let isEnabled: Bool
    public let calendars: [SetupCalendar]
    public let warnings: [String]
}

public struct SetupArm: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isMain: Bool
    public let isEnabled: Bool
    public let rule: ArmRuleMode
    public let sourceNames: [String]
    public let targetName: String
    public let sourceIDs: [String]
    public let targetID: String
}

public struct SetupSnapshot: Equatable, Sendable {
    public let connections: [SetupConnection]
    public let arms: [SetupArm]

    public var hasMainCalendar: Bool { arms.contains(where: \.isMain) }
}

/// What the Mac app calls for setup. Uses the same services and safety checks as the CLI, and writes no calendar events.
public struct SetupService: Sendable {
    private let makeRepository: @Sendable () throws -> LocalStateRepository

    public init() {
        makeRepository = { try CommandEnvironment.repository() }
    }

    init(makeRepository: @escaping @Sendable () throws -> LocalStateRepository) {
        self.makeRepository = makeRepository
    }

    public func snapshot() throws -> SetupSnapshot {
        let repository = try makeRepository()
        var namesByBinding: [String: String] = [:]
        let connections = try repository.connections().map { connection in
            let bindings = try repository.calendarBindings(connectionID: connection.id)
            for binding in bindings {
                namesByBinding[binding.id] = binding.displayLabel ?? binding.providerCalendarID
            }
            return SetupConnection(
                id: connection.id,
                provider: connection.provider,
                label: connection.displayLabel ?? connection.provider,
                isEnabled: connection.isEnabled,
                calendars: bindings.map {
                    SetupCalendar(
                        id: $0.id,
                        name: $0.displayLabel ?? $0.providerCalendarID,
                        sourceLabel: $0.providerSourceLabel,
                        isSelected: $0.isSelected,
                        isReadOnly: $0.isReadOnly,
                        providerColor: $0.providerColor
                    )
                },
                warnings: try CalendarSelectionSafety.warnings(
                    for: bindings,
                    connection: connection,
                    repository: repository
                )
            )
        }
        let arms = try repository.arms().map { arm in
            SetupArm(
                id: arm.id,
                name: arm.displayName,
                isMain: arm.isMain,
                isEnabled: arm.isEnabled,
                rule: arm.ruleMode,
                sourceNames: arm.sourceBindingIDs.map { namesByBinding[$0] ?? "Unknown calendar" },
                targetName: namesByBinding[arm.targetBindingID] ?? "Unknown calendar",
                sourceIDs: arm.sourceBindingIDs,
                targetID: arm.targetBindingID
            )
        }
        return SetupSnapshot(connections: connections, arms: arms)
    }

    public func connect(_ provider: SetupProvider) async throws {
        let connection: StoredConnection
        switch provider {
        case .google:
            connection = try await CommandEnvironment.googleService().authorize(
                using: LoopbackBrowserAuthorizationSession()
            )
        case .microsoft:
            connection = try await CommandEnvironment.microsoftService().authorize(
                using: LoopbackBrowserAuthorizationSession(
                    redirectHost: "localhost",
                    callbackPath: "/"
                )
            )
        case .mac:
            let runner = try EventKitHostRunner()
            let permission = try runner.requestPermission()
            guard permission.status == .fullAccess, permission.errorCode == nil else {
                throw ProviderFailure.permissionDenied
            }
            let response = try runner.perform(EventKitHostRequest(operation: .calendars))
            guard response.status == .fullAccess, response.errorCode == nil else {
                throw ProviderFailure.permissionDenied
            }
            connection = try CommandEnvironment.eventKitService().connect(
                calendars: response.calendars
            )
        }
        _ = try await refreshCalendars(for: connection)
    }

    public func refresh(connectionID: String) async throws {
        let repository = try makeRepository()
        guard let connection = try repository.connection(id: connectionID) else {
            throw SetupError.notFound
        }
        _ = try await refreshCalendars(for: connection)
    }

    public func disconnect(connectionID: String) throws {
        let repository = try makeRepository()
        guard let connection = try repository.connection(id: connectionID) else {
            throw SetupError.notFound
        }
        try CalopodCommands.disconnect(connection)
    }

    /// Blocks picking the same account through two connections.
    public func setSelected(calendarID: String, selected: Bool) throws {
        let repository = try makeRepository()
        guard let binding = try repository.calendarBinding(id: calendarID),
              let connection = try repository.connection(id: binding.connectionID) else {
            throw SetupError.notFound
        }
        if selected,
           let conflict = try CalendarSelectionSafety.conflictMessage(
               selecting: binding,
               on: connection,
               repository: repository
           ) {
            throw SetupError.blocked(conflict)
        }
        guard try repository.setCalendarSelection(id: calendarID, isSelected: selected) != nil else {
            throw SetupError.notFound
        }
    }

    /// The quick setup: one arm with full details and one that only shows Busy, both fed by the
    /// same sources. A nil target means that arm already exists. The full-details arm is stored
    /// as the Main calendar when none exists yet, so `calopod main` and calopod-setup still see it.
    public func setUpTwoArms(sourceIDs: [String], fullDetailsTargetID: String?, busyTargetID: String?) throws {
        let repository = try makeRepository()
        let arms = ArmConfigurationService(repository: repository)
        if let target = fullDetailsTargetID {
            if try repository.arms().contains(where: \.isMain) {
                _ = try arms.createArm(sourceBindingIDs: sourceIDs, targetBindingID: target, ruleMode: .fullDetails)
            } else {
                _ = try arms.configureMainCalendar(sourceBindingIDs: sourceIDs, targetBindingID: target)
            }
        }
        if let target = busyTargetID {
            _ = try arms.createArm(sourceBindingIDs: sourceIDs, targetBindingID: target, ruleMode: .busy)
        }
    }

    public func addArm(
        sourceIDs: [String],
        targetID: String,
        rule: ArmRuleMode,
        name: String?
    ) throws {
        let repository = try makeRepository()
        _ = try ArmConfigurationService(repository: repository).createArm(
            sourceBindingIDs: sourceIDs,
            targetBindingID: targetID,
            ruleMode: rule,
            name: name
        )
    }

    public func setRule(armID: String, rule: ArmRuleMode) throws {
        let repository = try makeRepository()
        _ = try ArmConfigurationService(repository: repository).updateRule(
            armID: armID,
            ruleMode: rule
        )
    }

    public func setArmEnabled(armID: String, enabled: Bool) throws {
        let repository = try makeRepository()
        guard try repository.setArmEnabled(id: armID, isEnabled: enabled) != nil else {
            throw SetupError.notFound
        }
    }

    public func removeArm(armID: String) throws {
        let repository = try makeRepository()
        guard try repository.arm(id: armID) != nil else { throw SetupError.notFound }
        try repository.removeArm(id: armID)
    }

    public func message(for error: Error) -> String {
        switch error {
        case SetupError.notFound:
            return "That item no longer exists. Refresh and try again."
        case let SetupError.blocked(message):
            return message
        case let arm as ArmConfigurationError:
            return arm.description
        default:
            return commandFailure(error).message
        }
    }
}

public enum SetupError: Error, Equatable, Sendable {
    case notFound
    case blocked(String)
}
#endif
