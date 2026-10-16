#if os(macOS)
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
