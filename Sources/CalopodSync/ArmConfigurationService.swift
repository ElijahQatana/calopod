import CalopodDomain
import CalopodStore
import Foundation

/// Reasons an Arm cannot be created or changed. Each case maps to one
/// invariant enforced before anything is persisted, so callers can show a
/// precise, actionable message instead of a generic failure.
public enum ArmConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName
    case noSources
    case armNotFound(String)
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
    case mainCalendarAlreadyConfigured
    case mainCalendarRuleFixed

    public var description: String {
        switch self {
        case .invalidName:
            "Use an Arm name of up to 200 characters without control characters."
        case .noSources:
            "Choose at least one source calendar."
        case let .armNotFound(id):
            "Arm '\(id)' was not found."
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
        case .mainCalendarAlreadyConfigured:
            "A Main calendar is already configured."
        case .mainCalendarRuleFixed:
            "The Main calendar always uses the Full details Rule."
        }
    }
}

/// Creates and updates Arms: the sync and publish relationships that route
/// one or more source calendars to a single target calendar. This is the
/// only place new Arms are validated, so every safety rule that keeps
/// routing sane (no self-routes, no duplicate routes, one Main calendar, a
/// single preferred writer per EventKit target) lives here rather than
/// being re-checked by each caller.
public struct ArmConfigurationService: Sendable {
    private let repository: LocalStateRepository

    public init(repository: LocalStateRepository) {
        self.repository = repository
    }

    public func rename(armID: String, name: String?, now: Date = Date()) throws -> StoredArm {
        let normalized = try normalizedName(name)
        guard let arm = try repository.setArmName(id: armID, name: normalized, now: now) else {
            throw ArmConfigurationError.armNotFound(armID)
        }
        return arm
    }

    private func normalizedName(_ name: String?) throws -> String? {
        guard let name else { return nil }
        guard name.count <= 200,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArmConfigurationError.invalidName
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func updateRule(
        armID: String,
        ruleMode: ArmRuleMode,
        now: Date = Date()
    ) throws -> StoredArm {
        guard let existing = try repository.arm(id: armID) else {
            throw ArmConfigurationError.armNotFound(armID)
        }
        if existing.isMain && ruleMode != .fullDetails {
            throw ArmConfigurationError.mainCalendarRuleFixed
        }
        guard let arm = try repository.setArmRuleMode(
            id: armID,
            ruleMode: ruleMode,
            now: now
        ) else {
            throw ArmConfigurationError.armNotFound(armID)
        }
        return arm
    }

    @discardableResult
    public func configureMainCalendar(
        id: String = UUID().uuidString.lowercased(),
        sourceBindingIDs: [String],
        targetBindingID: String,
        now: Date = Date()
    ) throws -> StoredArm {
        try createArm(
            id: id,
            sourceBindingIDs: sourceBindingIDs,
            targetBindingID: targetBindingID,
            ruleMode: .fullDetails,
            isMain: true,
            now: now
        )
    }

    public func preferCurrentDevice(
        armID: String,
        now: Date = Date()
    ) throws -> StoredArm {
        guard let existing = try repository.arm(id: armID) else {
            throw ArmConfigurationError.armNotFound(armID)
        }
        let device = try repository.currentDevice(
            configurationID: existing.configurationID,
            now: now
        )
        guard let arm = try repository.setArmPreferredWriter(
            id: armID,
            deviceID: device.id,
            now: now
        ) else {
            throw ArmConfigurationError.armNotFound(armID)
        }
        return arm
    }

    @discardableResult
    public func createArm(
        id: String = UUID().uuidString.lowercased(),
        sourceBindingIDs: [String],
        targetBindingID: String,
        ruleMode: ArmRuleMode = .busy,
        isMain: Bool = false,
        name: String? = nil,
        now: Date = Date()
    ) throws -> StoredArm {
        let name = try normalizedName(name)
        // Validation runs cheapest-and-most-local checks first (shape of the
        // input) before touching the repository, so a malformed request never
        // pays for a lookup it was always going to fail.
        if isMain && ruleMode != .fullDetails {
            throw ArmConfigurationError.mainCalendarRuleFixed
        }
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

        if isMain {
            let hasMainCalendar = try repository.arms().contains(where: \.isMain)
            if hasMainCalendar {
                throw ArmConfigurationError.mainCalendarAlreadyConfigured
            }
        }

        // Reciprocal routes are safe because source ingestion excludes managed
        // copies. Keep each original source-to-target route unique across Arms.
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
            routes[sourceID, default: []].insert(targetBindingID)
        }

        // EventKit calendars are only safe to write from one device at a
        // time (there is no server-side conflict resolution like the hosted
        // providers have), so a new Arm targeting EventKit locks in the
        // creating device as the sole writer up front.
        let preferredWriterDeviceID: String?
        if targetConnection.provider == ProviderKind.eventKit.rawValue {
            preferredWriterDeviceID = try repository.currentDevice(
                configurationID: targetConnection.configurationID,
                now: now
            ).id
        } else {
            preferredWriterDeviceID = nil
        }
        let arm = StoredArm(
            id: id,
            configurationID: targetConnection.configurationID,
            sourceBindingIDs: sourceBindingIDs.sorted(),
            targetBindingID: targetBindingID,
            ruleMode: ruleMode,
            preferredWriterDeviceID: preferredWriterDeviceID,
            isMain: isMain,
            name: name
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
}

/// Gate on whether *this* device is allowed to write to an Arm's target.
/// Hosted providers (Google, Microsoft) tolerate writes from any device, but
/// an EventKit target has exactly one preferred writer recorded on the Arm;
/// every other device must skip applying and leave that target alone.
public enum ArmWriterPolicy {
    public static func allowsApply(
        arm: StoredArm,
        targetProvider: ProviderKind,
        currentDeviceID: String
    ) -> Bool {
        targetProvider != .eventKit || arm.preferredWriterDeviceID == currentDeviceID
    }
}
