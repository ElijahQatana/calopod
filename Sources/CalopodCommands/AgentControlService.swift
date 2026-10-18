#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import Foundation

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

/// What a sync would change. Lines carry the event title and time when this Mac still knows them.
public struct SyncPreview: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: String
        public let armName: String
        /// One of `create`, `update`, `remove`, `repair`.
        public let action: String
        public let reason: String
        /// The source event's title. Nil for a copy whose source is gone.
        public let title: String?
        public let startsAt: Date?
        public let endsAt: Date?
        public let isAllDay: Bool
        /// Where the event comes from, when known.
        public let sourceCalendarID: String?
        /// The calendar that holds, or will hold, the copy.
        public let targetCalendarID: String

        public init(
            id: String, armName: String, action: String, reason: String, title: String? = nil,
            startsAt: Date? = nil, endsAt: Date? = nil, isAllDay: Bool = false,
            sourceCalendarID: String? = nil, targetCalendarID: String
        ) {
            self.id = id
            self.armName = armName
            self.action = action
            self.reason = reason
            self.title = title
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.isAllDay = isAllDay
            self.sourceCalendarID = sourceCalendarID
            self.targetCalendarID = targetCalendarID
        }

        static func make(
            item: SyncPlanItem, arm: StoredArm?, armName: String, source: StoredNormalizedInstance?
        ) -> Line {
            Line(
                id: item.id, armName: armName, action: item.action.rawValue,
                reason: AgentControlService.reasonText(item.reason),
                title: source?.title ?? item.payload?.title,
                startsAt: source?.startsAt ?? item.payload?.startsAt,
                endsAt: source?.endsAt ?? item.payload?.endsAt,
                isAllDay: source?.isAllDay ?? item.payload?.isAllDay ?? false,
                sourceCalendarID: source?.calendarBindingID,
                targetCalendarID: arm?.targetBindingID ?? ""
            )
        }
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

public struct HealthReport: Equatable, Sendable {
    public struct Check: Identifiable, Equatable, Sendable {
        public var id: String { name }
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

/// Controls the background service for the Mac app, through the same code as `calopod agent`.
public struct AgentControlService: Sendable {
    public static let bundledLabel = "pro.elijahquintana.calopod.app-agent"

    /// Matches the bundled agent's plist in Support/Mac.
    private static let bundledSchedule = (
        interval: 600, jitter: 30, lookbackDays: 1, horizonDays: 4
    )

    private let bundledAgentExecutable: URL?
    private let makeController: @Sendable () throws -> LaunchAgentController
    private let baseEnvironment: @Sendable () -> [String: String]

    /// Pass the bundled agent only while it is registered. An enabled source-installed agent still wins.
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

    private struct Context {
        let snapshot: LaunchAgentSnapshot
        let environment: () throws -> CalopodRuntimeEnvironment
        let schedule: () throws -> AgentSchedule
        let isBundled: Bool
    }

    private func context() throws -> Context {
        let controller = try makeController()
        let snapshot = try controller.snapshot()
        // Moving to the app disables the source install, which is when the bundled agent takes over.
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
        try status(in: try context())
    }

    private func status(in context: Context) throws -> AgentControlStatus {
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

    /// The bundled agent is registered and removed by the app, not here.
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
        // The agent reads the flag before each run, so only the source install is restarted.
        if !context.isBundled {
            try makeController().restartIfEnabled()
        }
    }

    /// The bundled agent reads the new interval from a file. The source install gets its plist rewritten.
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

    /// Runs one sync now, ignoring the pause flag, like `agent run-now`.
    public func syncNow() async throws -> AgentRunReport {
        let context = try context()
        return await CalopodAgentRunner(
            environment: try context.environment(),
            schedule: try context.schedule()
        ).runOnce(ignorePause: true)
    }

    /// Status, overview and health from one reading of the service, so a poll launches launchctl once
    /// instead of three times. Each part is nil when it could not be read.
    public func state() -> (status: AgentControlStatus?, overview: AgentControlOverview?, health: HealthReport?) {
        guard let context = try? context() else { return (nil, nil, nil) }
        return (try? status(in: context), try? overview(in: context), try? health(in: context))
    }

    public func health() throws -> HealthReport {
        try health(in: try context())
    }

    private func health(in context: Context) throws -> HealthReport {
        Self.healthReport(
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

    /// Dry run over the automatic sync window.
    public func preview() async throws -> SyncPreview {
        let context = try context()
        let environment = try context.environment()
        let schedule = try context.schedule()
        let repository = try environment.repository()
        let arms = Dictionary(uniqueKeysWithValues: try repository.arms().map { ($0.id, $0) })
        let window = try schedule.window(containing: Date())
        let result = try await SyncEngine(environment: environment).run(
            SyncRequest(mode: .dryRun, window: window),
            trigger: .manual
        )
        let sources = Dictionary(
            try repository.normalizedInstances(
                calendarBindingIDs: Array(Set(arms.values.flatMap(\.sourceBindingIDs))),
                from: window.start, through: window.end
            ).map { ($0.sourceKeyHash, $0) },
            uniquingKeysWith: { first, _ in first }
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
                SyncPreview.Line.make(
                    item: $0, arm: arms[$0.armID], armName: arms[$0.armID]?.displayName ?? "Unknown Arm",
                    source: $0.sourceKeyHash.flatMap { sources[$0] }
                )
            }
        )
    }

    static func reasonText(_ reason: SyncPlanReason) -> String {
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
        try overview(in: try context())
    }

    private func overview(in context: Context) throws -> AgentControlOverview {
        let repository = try context.environment().repository()
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

    public func message(for error: Error) -> String {
        commandFailure(error).message
    }
}
#endif
