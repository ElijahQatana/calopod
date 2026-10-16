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

/// The `calopod doctor` checks, for the Mac app's Health section.
public struct HealthReport: Equatable, Sendable {
    public struct Check: Identifiable, Equatable, Sendable {
        public var id: String { name }
        /// `installation`, `service`, `state`, `database`, `schedule`, `connections` and so on.
        public let name: String
        /// `ok`, `pending` or `failed`.
        public let state: String
        public let reason: String?
    }

    /// `ok`, `attention` or `failed`.
    public let status: String
    public let message: String
    public let checks: [Check]
    public let warnings: [String]
}

/// Stateless entry point the Mac app uses to control the background service. Each call goes
/// through the same `LaunchAgentController` and runner as the `calopod agent` commands.
public struct AgentControlService: Sendable {
    /// Label of the agent bundled in Calopod.app and registered through SMAppService.
    public static let bundledLabel = "pro.elijahquintana.calopod.app-agent"

    /// Schedule baked into the bundled agent's plist (Support/Mac). Keep these in sync.
    private static let bundledSchedule = (
        interval: 600, jitter: 30, lookbackDays: 1, horizonDays: 4
    )

    private let bundledAgentExecutable: URL?
    private let makeController: @Sendable () throws -> LaunchAgentController
    private let baseEnvironment: @Sendable () -> [String: String]

    /// - Parameter bundledAgentExecutable: the `calopod-agent` inside Calopod.app, passed only
    ///   while that agent is registered. The source-installed LaunchAgent, when present, wins.
    public init(bundledAgentExecutable: URL? = nil) {
        self.init(
            bundledAgentExecutable: bundledAgentExecutable,
            makeController: { try LaunchAgentController() },
            baseEnvironment: { ProcessInfo.processInfo.environment }
        )
    }

    init(
        bundledAgentExecutable: URL?,
        makeController: @escaping @Sendable () throws -> LaunchAgentController,
        baseEnvironment: @escaping @Sendable () -> [String: String]
    ) {
        self.bundledAgentExecutable = bundledAgentExecutable
        self.makeController = makeController
        self.baseEnvironment = baseEnvironment
    }

    /// Everything a control needs to act on whichever service is active.
    private struct Context {
        let snapshot: LaunchAgentSnapshot
        let environment: () throws -> CalopodRuntimeEnvironment
        let schedule: () throws -> AgentSchedule
        let isBundled: Bool
    }

    private func context() throws -> Context {
        let controller = try makeController()
        let snapshot = try controller.snapshot()
        // The source-installed service is used unless the bundled one is registered and the
        // source-installed one has been disabled, which is what moving to the app does.
        if let configuration = snapshot.configuration,
           bundledAgentExecutable == nil || !snapshot.disabled {
            return Context(
                snapshot: snapshot,
                environment: { try installedAgentEnvironment(controller: controller) },
                schedule: { try AgentSchedule(environment: configuration.environment) },
                isBundled: false
            )
        }
        guard let executable = bundledAgentExecutable else {
            return Context(
                snapshot: snapshot,
                environment: { throw LaunchAgentControlError.notInstalled },
                schedule: { throw LaunchAgentControlError.notInstalled },
                isBundled: false
            )
        }
        let defaults = Self.bundledSchedule
        var variables = baseEnvironment()
        variables["CALOPOD_AGENT_INTERVAL_SECONDS"] = String(defaults.interval)
        variables["CALOPOD_AGENT_JITTER_SECONDS"] = String(defaults.jitter)
        variables["CALOPOD_AGENT_LOOKBACK_DAYS"] = String(defaults.lookbackDays)
        variables["CALOPOD_AGENT_HORIZON_DAYS"] = String(defaults.horizonDays)
        let location = try CalopodStateLocation(environment: variables)
        let override = AgentScheduleOverride.load(from: location)
        let loaded = (try? controller.isLoaded(label: Self.bundledLabel)) ?? false
        let configuration = AgentServiceConfiguration(
            programURL: executable,
            stateURL: location.databaseURL,
            eventKitHostURL: executable.deletingLastPathComponent()
                .appendingPathComponent("eventkit-host/Calopod EventKit Host.app", isDirectory: true),
            intervalSeconds: override?.intervalSeconds ?? defaults.interval,
            jitterSeconds: defaults.jitter,
            lookbackDays: defaults.lookbackDays,
            horizonDays: defaults.horizonDays,
            environment: variables
        )
        return Context(
            snapshot: LaunchAgentSnapshot(
                installed: true,
                loaded: loaded,
                disabled: false,
                configuration: configuration
            ),
            environment: {
                try CalopodRuntimeEnvironment(
                    variables: variables,
                    stateLocation: location,
                    executableURL: executable
                )
            },
            schedule: { try AgentSchedule(environment: variables).applying(override) },
            isBundled: true
        )
    }

    public func status() throws -> AgentControlStatus {
        let context = try context()
        let payload = try agentStatusPayload(
            snapshot: context.snapshot,
            environment: context.environment
        )
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

    /// Starts or stops the source-installed LaunchAgent. The bundled agent is registered and
    /// removed by the app through SMAppService, not here.
    public func setEnabled(_ enabled: Bool) throws {
        guard !(try context().isBundled) else { throw LaunchAgentControlError.unavailable }
        let controller = try makeController()
        if enabled {
            try controller.enable()
        } else {
            try controller.disable()
        }
    }

    public func setPaused(_ paused: Bool) throws {
        let context = try context()
        try context.environment().repository().setAgentPaused(paused)
        // The agent checks the flag before every run, so only the legacy service is restarted.
        if !context.isBundled {
            try makeController().restartIfEnabled()
        }
    }

    /// Changes how often automatic sync runs. The bundled agent picks the new interval up from a
    /// state-side file within seconds; the source-installed one has it rewritten in its plist.
    public func setInterval(seconds: Int) throws {
        let context = try context()
        let environment = try context.environment()
        if context.isBundled {
            try AgentScheduleOverride(intervalSeconds: seconds).save(to: environment.stateLocation)
        } else {
            try makeController().updateSchedule(intervalSeconds: seconds, jitterSeconds: nil)
            AgentScheduleOverride.clear(from: environment.stateLocation)
        }
    }

    /// Runs one bounded synchronization now, ignoring the pause flag, like `agent run-now`.
    public func syncNow() async throws -> AgentRunReport {
        let context = try context()
        return await CalopodAgentRunner(
            environment: try context.environment(),
            schedule: try context.schedule()
        ).runOnce(ignorePause: true)
    }

    public func health() throws -> HealthReport {
        let context = try context()
        return Self.healthReport(
            try doctorReport(snapshot: context.snapshot, environment: context.environment)
        )
    }

    static func health(controller: LaunchAgentController) throws -> HealthReport {
        healthReport(try doctorReport(controller: controller))
    }

    private static func healthReport(_ report: DoctorReport) -> HealthReport {
        HealthReport(
            status: report.status,
            message: report.message,
            checks: report.items.map {
                HealthReport.Check(name: $0.id, state: $0.kind, reason: $0.reason)
            },
            warnings: report.warnings
        )
    }

    /// Plans one bounded sync over the automatic-sync window without writing to any calendar.
    public func preview() async throws -> SyncPreview {
        let context = try context()
        let environment = try context.environment()
        let schedule = try context.schedule()
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
        let repository = try context().environment().repository()
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
