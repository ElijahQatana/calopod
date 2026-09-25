import CalopodDomain
import CalopodStore
import Foundation

public enum ArmConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSources
    case duplicateSource(String)
    case calendarNotFound(String)
    case sourceNotSelected(String)
    case connectionNotFound(String)
    case connectionDisabled(String)
    case targetReadOnly(String)
    case targetProviderReadOnly(String)
    case mixedConfigurations
    case sourceMatchesTarget(String)
    case duplicateRoute(source: String, target: String)
    case unsafeCycle

    public var description: String {
        switch self {
        case .noSources:
            "Choose at least one source calendar."
        case let .duplicateSource(id):
            "Source calendar '\(id)' was provided more than once."
        case let .calendarNotFound(id):
            "Calendar '\(id)' was not found."
        case let .sourceNotSelected(id):
            "Source calendar '\(id)' is not selected."
        case let .connectionNotFound(id):
            "Connection '\(id)' was not found."
        case let .connectionDisabled(id):
            "Connection '\(id)' is disabled."
        case let .targetReadOnly(id):
            "Target calendar '\(id)' is read only."
        case let .targetProviderReadOnly(id):
            "Target calendar '\(id)' belongs to a read-only provider."
        case .mixedConfigurations:
            "Every source and target calendar must belong to the same configuration."
        case let .sourceMatchesTarget(id):
            "Calendar '\(id)' cannot be both a source and target on the same Arm."
        case let .duplicateRoute(source, target):
            "An Arm already routes source '\(source)' to target '\(target)'."
        case .unsafeCycle:
            "That Arm would create an unsafe source and target cycle."
        }
    }
}

public struct ArmConfigurationService: Sendable {
    private let repository: LocalStateRepository

    public init(repository: LocalStateRepository) {
        self.repository = repository
    }

    @discardableResult
    public func createArm(
        id: String = UUID().uuidString.lowercased(),
        sourceBindingIDs: [String],
        targetBindingID: String,
        ruleMode: ArmRuleMode = .busy,
        now: Date = Date()
    ) throws -> StoredArm {
        guard !sourceBindingIDs.isEmpty else {
            throw ArmConfigurationError.noSources
        }
        var seenSources = Set<String>()
        for sourceID in sourceBindingIDs where !seenSources.insert(sourceID).inserted {
            throw ArmConfigurationError.duplicateSource(sourceID)
        }
        if seenSources.contains(targetBindingID) {
            throw ArmConfigurationError.sourceMatchesTarget(targetBindingID)
        }

        let target = try requiredBinding(id: targetBindingID)
        let targetConnection = try requiredConnection(id: target.connectionID)
        guard targetConnection.isEnabled else {
            throw ArmConfigurationError.connectionDisabled(targetConnection.id)
        }
        guard !target.isReadOnly else {
            throw ArmConfigurationError.targetReadOnly(target.id)
        }
        guard targetConnection.provider != ProviderKind.ics.rawValue else {
            throw ArmConfigurationError.targetProviderReadOnly(target.id)
        }

        for sourceID in sourceBindingIDs {
            let source = try requiredBinding(id: sourceID)
            let connection = try requiredConnection(id: source.connectionID)
            guard connection.isEnabled else {
                throw ArmConfigurationError.connectionDisabled(connection.id)
            }
            guard source.isSelected else {
                throw ArmConfigurationError.sourceNotSelected(source.id)
            }
            guard connection.configurationID == targetConnection.configurationID else {
                throw ArmConfigurationError.mixedConfigurations
            }
        }

        let existing = try repository.arms(configurationID: targetConnection.configurationID)
        var routes: [String: Set<String>] = [:]
        for arm in existing {
            for sourceID in arm.sourceBindingIDs {
                routes[sourceID, default: []].insert(arm.targetBindingID)
            }
        }
        for sourceID in sourceBindingIDs {
            if routes[sourceID]?.contains(targetBindingID) == true {
                throw ArmConfigurationError.duplicateRoute(
                    source: sourceID,
                    target: targetBindingID
                )
            }
            if hasPath(from: targetBindingID, to: sourceID, routes: routes) {
                throw ArmConfigurationError.unsafeCycle
            }
            routes[sourceID, default: []].insert(targetBindingID)
        }

        let arm = StoredArm(
            id: id,
            configurationID: targetConnection.configurationID,
            sourceBindingIDs: sourceBindingIDs.sorted(),
            targetBindingID: targetBindingID,
            ruleMode: ruleMode
        )
        try repository.saveArm(arm, now: now)
        return arm
    }

    private func requiredBinding(id: String) throws -> StoredCalendarBinding {
        guard let binding = try repository.calendarBinding(id: id) else {
            throw ArmConfigurationError.calendarNotFound(id)
        }
        return binding
    }

    private func requiredConnection(id: String) throws -> StoredConnection {
        guard let connection = try repository.connection(id: id) else {
            throw ArmConfigurationError.connectionNotFound(id)
        }
        return connection
    }

    private func hasPath(
        from start: String,
        to destination: String,
        routes: [String: Set<String>]
    ) -> Bool {
        var pending = [start]
        var visited = Set<String>()
        while let current = pending.popLast() {
            if current == destination { return true }
            guard visited.insert(current).inserted else { continue }
            pending.append(contentsOf: routes[current] ?? [])
        }
        return false
    }
}
