#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import Foundation

/// What the Mac app shows about automatic sync. A public mirror of the `agent status` payload.
public struct AgentControlStatus: Equatable, Sendable {
    /// One of `ok`, `paused`, `disabled`, `stopped`, `failed`, `not-installed`.
    public let state: String
    public let message: String
    public let installed: Bool
    public let enabled: Bool
    public let paused: Bool
    public let running: Bool
    public let intervalSeconds: Int?
    public let lastSuccessAgeSeconds: Int?
    public let failureCategory: String?
}

public struct AgentControlOverview: Equatable, Sendable {
    public struct ConnectionLine: Equatable, Sendable, Identifiable {
        public let id: String
        public let provider: String
        public let label: String
        public let isEnabled: Bool
        public let selectedCalendarCount: Int
    }

    public struct ArmLine: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let sourceCount: Int
        public let isEnabled: Bool
    }

    public let connections: [ConnectionLine]
    public let arms: [ArmLine]
}

/// What a sync would do, planned without writing any provider data. Counts and reasons only: no
/// event titles or notes.
public struct SyncPreview: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: String
        public let armName: String
        /// One of `create`, `update`, `remove`, `repair`.
        public let action: String
        public let reason: String
    }

    public let creates: Int
    public let updates: Int
    public let removals: Int
    public let repairs: Int
    public let noOps: Int
    public let warnings: [String]
    /// Every planned change; unchanged events are only counted.
    public let lines: [Line]

    public var changeCount: Int { creates + updates + removals + repairs }
}

/// Stateless entry point the Mac app uses to control the background service. Each call goes
/// through the same `LaunchAgentController` and runner as the `calopod agent` commands.
public struct AgentControlService: Sendable {
    public init() {}

    public func status() throws -> AgentControlStatus {
        let payload = try agentStatusPayload(controller: try LaunchAgentController())
        return AgentControlStatus(
            state: payload.status,
            message: payload.message,
            installed: payload.installed ?? false,
            enabled: payload.enabled ?? false,
            paused: payload.paused ?? false,
            running: payload.runState == "running",
            intervalSeconds: payload.intervalSeconds,
            lastSuccessAgeSeconds: payload.lastSuccessAgeSeconds,
            failureCategory: payload.failureCategory
        )
    }

    public func setEnabled(_ enabled: Bool) throws {
        let controller = try LaunchAgentController()
        if enabled {
            try controller.enable()
        } else {
            try controller.disable()
        }
    }

    public func setPaused(_ paused: Bool) throws {
        let controller = try LaunchAgentController()
        let environment = try installedAgentEnvironment(controller: controller)
        try environment.repository().setAgentPaused(paused)
        try controller.restartIfEnabled()
    }

    public func setInterval(seconds: Int) throws {
        try LaunchAgentController().updateSchedule(
            intervalSeconds: seconds,
            jitterSeconds: nil
        )
    }

    /// Runs one bounded synchronization now, ignoring the pause flag, like `agent run-now`.
    public func syncNow() async throws -> AgentRunReport {
        let controller = try LaunchAgentController()
        guard let configuration = try controller.snapshot().configuration else {
            throw LaunchAgentControlError.notInstalled
        }
        let environment = try installedAgentEnvironment(controller: controller)
        return await CalopodAgentRunner(
            environment: environment,
            schedule: try AgentSchedule(environment: configuration.environment)
        ).runOnce(ignorePause: true)
    }

    /// Plans one bounded sync over the automatic-sync window without writing to any calendar.
    public func preview() async throws -> SyncPreview {
        let controller = try LaunchAgentController()
        guard let configuration = try controller.snapshot().configuration else {
            throw LaunchAgentControlError.notInstalled
        }
        let environment = try installedAgentEnvironment(controller: controller)
        let schedule = try AgentSchedule(environment: configuration.environment)
        let armNames = Dictionary(
            uniqueKeysWithValues: try environment.repository().arms().map { ($0.id, $0.displayName) }
        )
        let result = try await SyncEngine(environment: environment).run(
            SyncRequest(mode: .dryRun, window: try schedule.window(containing: Date())),
            trigger: .manual
        )
        func count(_ action: SyncPlanAction) -> Int {
            result.items.filter { $0.action == action }.count
        }
        return SyncPreview(
            creates: count(.create),
            updates: count(.update),
            removals: count(.remove),
            repairs: count(.repair),
            noOps: result.noOpCount + count(.noOp),
            warnings: result.warnings,
            lines: result.items.filter { $0.action != .noOp }.map {
                SyncPreview.Line(
                    id: $0.id,
                    armName: armNames[$0.armID] ?? "Unknown Arm",
                    action: $0.action.rawValue,
                    reason: Self.reasonText($0.reason)
                )
            }
        )
    }

    private static func reasonText(_ reason: SyncPlanReason) -> String {
        switch reason {
        case .targetMissing: "Not on the target calendar yet"
        case .targetDiffers: "Target copy is out of date"
        case .targetMatches: "Already up to date"
        case .sourceMissing: "No longer on the source calendar"
        case .verifiedDuplicates: "Duplicate copies found"
        case .mappingMissing: "Copy exists but is not tracked"
        case .providerIdentityChanged: "Calendar account changed"
        case .ownershipUnverified: "Could not confirm Calopod owns this copy"
        case .sourceSnapshotIncomplete: "Source calendar could not be fully read"
        case .targetSnapshotIncomplete: "Target calendar could not be fully read"
        }
    }

    public func overview() throws -> AgentControlOverview {
        let controller = try LaunchAgentController()
        let repository = try installedAgentEnvironment(controller: controller).repository()
        let connections = try repository.connections().map { connection in
            AgentControlOverview.ConnectionLine(
                id: connection.id,
                provider: connection.provider,
                label: connection.displayLabel ?? connection.provider,
                isEnabled: connection.isEnabled,
                selectedCalendarCount: try repository
                    .calendarBindings(connectionID: connection.id)
                    .filter(\.isSelected)
                    .count
            )
        }
        let arms = try repository.arms().map { arm in
            AgentControlOverview.ArmLine(
                id: arm.id,
                name: arm.displayName,
                sourceCount: arm.sourceBindingIDs.count,
                isEnabled: arm.isEnabled
            )
        }
        return AgentControlOverview(connections: connections, arms: arms)
    }

    /// Plain-language text for any error thrown by this service.
    public func message(for error: Error) -> String {
        commandFailure(error).message
    }
}
#endif
