#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import Foundation
import ServiceManagement

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
    /// How long ago the last automatic run failed, when it did and nothing newer has run.
    public let failureAgeSeconds: Int?
    /// True when the numbers above describe the app's own service, not a source install.
    public let usesBundledService: Bool
    /// A source-installed agent is loaded in launchd right now, whichever service is reported.
    public let sourceLoaded: Bool
    /// The window each run covers, when the service's schedule is known.
    public var lookbackDays: Int? = nil
    public var horizonDays: Int? = nil
    /// The source install is switched on in launchd, loaded or not.
    public var sourceEnabled = false
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

    private let bundledAgentExecutable: URL?
    private let makeController: @Sendable () throws -> LaunchAgentController
    private let baseEnvironment: @Sendable () -> [String: String]
    private let reregisterBundled: @Sendable () async throws -> Void

    /// Pass the bundled agent only while it is registered and approved. Then it is the live service,
    /// and the source install is only reported on.
    public init(bundledAgentExecutable: URL? = nil) {
        self.init(
            bundledAgentExecutable: bundledAgentExecutable,
            makeController: { try LaunchAgentController() },
            baseEnvironment: { ProcessInfo.processInfo.environment },
            reregisterBundled: {
                let service = SMAppService.agent(plistName: BackgroundServiceState.agentPlistName)
                try await service.unregister()
                try service.register()
            }
        )
    }

    /// The service for whoever is running: the app's own agent when this copy of Calopod has it
    /// registered and approved, otherwise the source install. Works from the app and its command.
    public static func current(registration: BackgroundServiceState = .read()) -> AgentControlService {
        guard registration == .enabled else { return AgentControlService() }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/calopod-agent")
        return AgentControlService(bundledAgentExecutable: executable)
    }

    init(
        bundledAgentExecutable: URL?,
        makeController: @escaping @Sendable () throws -> LaunchAgentController,
        baseEnvironment: @escaping @Sendable () -> [String: String],
        reregisterBundled: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.bundledAgentExecutable = bundledAgentExecutable
        self.makeController = makeController
        self.baseEnvironment = baseEnvironment
        self.reregisterBundled = reregisterBundled
    }

    private struct Context {
        let snapshot: LaunchAgentSnapshot
        let environment: () throws -> CalopodRuntimeEnvironment
        let schedule: () throws -> AgentSchedule
        let isBundled: Bool
        /// The source install is loaded in launchd, even when the bundled agent is the one in use.
        var sourceLoaded: Bool { sourceSnapshot.loaded }
        var sourceEnabled: Bool { sourceSnapshot.installed && !sourceSnapshot.disabled }
        let sourceSnapshot: LaunchAgentSnapshot
    }

    private func context() throws -> Context {
        let controller = try makeController()
        let snapshot = try controller.snapshot()
        // The bundled agent is the live service whenever it is registered. A source install that is
        // also on is reported, never described as the one in use.
        if let configuration = snapshot.configuration, bundledAgentExecutable == nil {
            return Context(
                snapshot: snapshot,
                environment: { try installedAgentEnvironment(controller: controller) },
                schedule: { try AgentSchedule(environment: configuration.environment) },
                isBundled: false,
                sourceSnapshot: snapshot
            )
        }
        guard let executable = bundledAgentExecutable else {
            return Context(
                snapshot: snapshot,
                environment: { throw LaunchAgentControlError.notInstalled },
                schedule: { throw LaunchAgentControlError.notInstalled },
                isBundled: false,
                sourceSnapshot: snapshot
            )
        }
        // The bundled plist gives no numbers; the agent falls back to the same defaults.
        var variables = baseEnvironment().merging(AgentScheduleDefaults.environment) { _, defaults in defaults }
        let location = try CalopodStateLocation(environment: variables)
        let override = AgentScheduleOverride.load(from: location)
        let loaded = (try? controller.isLoaded(label: Self.bundledLabel)) ?? false
        let configuration = AgentServiceConfiguration(
            programURL: executable,
            stateURL: location.databaseURL,
            eventKitHostURL: executable.deletingLastPathComponent()
                .appendingPathComponent("eventkit-host/Calopod EventKit Host.app", isDirectory: true),
            intervalSeconds: override?.intervalSeconds ?? AgentScheduleDefaults.intervalSeconds,
            jitterSeconds: AgentScheduleDefaults.jitterSeconds,
            lookbackDays: AgentScheduleDefaults.lookbackDays,
            horizonDays: AgentScheduleDefaults.horizonDays,
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
            isBundled: true,
            sourceSnapshot: snapshot
        )
    }

    func statusPayload() throws -> CommandPayload {
        let context: Context
        do {
            context = try self.context()
        } catch is AgentServiceConfigurationError {
            return CommandPayload(
                status: "failed", message: "The automatic-sync configuration is invalid.",
                installed: true, failureCategory: "configuration")
        }
        return try agentStatusPayload(snapshot: context.snapshot, environment: context.environment)
    }

    /// The result printed after a control command, from the service that is live.
    func controlResult(message: String) throws -> CommandPayload {
        let context = try context()
        let snapshot = context.snapshot
        var paused = false
        if let configuration = snapshot.configuration, FileManager.default.fileExists(atPath: configuration.stateURL.path) {
            paused = try context.environment().repository().agentControl().isPaused
        }
        return CommandPayload(
            status: "ok", message: message, installed: snapshot.installed,
            enabled: snapshot.installed && !snapshot.disabled, paused: paused,
            runState: snapshot.loaded ? "running" : "stopped",
            stateReady: snapshot.configuration.map { FileManager.default.fileExists(atPath: $0.stateURL.path) },
            intervalSeconds: snapshot.configuration?.intervalSeconds, jitterSeconds: snapshot.configuration?.jitterSeconds,
            lookbackDays: snapshot.configuration?.lookbackDays, horizonDays: snapshot.configuration?.horizonDays)
    }

    func doctor() throws -> DoctorReport {
        let context: Context
        do {
            context = try self.context()
        } catch is AgentServiceConfigurationError {
            return DoctorReport(
                status: "failed", message: "The automatic-sync installation needs attention.",
                items: [CommandItem(id: "installation", kind: "failed", reason: "configuration")],
                warnings: ["Reinstall the Calopod user service."])
        }
        return try doctorReport(
            snapshot: context.snapshot, environment: context.environment,
            usesBundled: context.isBundled, sourceLoaded: context.sourceLoaded)
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
            failureCategory: payload.failureCategory,
            failureAgeSeconds: payload.failureCategory == nil ? nil : failureAge(in: context),
            usesBundledService: context.isBundled,
            sourceLoaded: context.sourceLoaded,
            lookbackDays: context.snapshot.configuration?.lookbackDays,
            horizonDays: context.snapshot.configuration?.horizonDays,
            sourceEnabled: context.sourceEnabled
        )
    }

    private func failureAge(in context: Context) -> Int? {
        guard let run = try? context.environment().repository().latestSyncRun(trigger: "automatic"),
              run.status == "failed" || run.status == "interrupted" else { return nil }
        return max(0, Int(Date().timeIntervalSince(run.finishedAt ?? run.startedAt)))
    }

    /// How the last sync runs ended, oldest first. Empty when the history cannot be read.
    public func recentRuns(limit: Int = RunMark.barCount) -> [RunMark] {
        guard let context = try? context(), let repository = try? context.environment().repository() else { return [] }
        return (try? repository.recentRunMarks(limit: limit)) ?? []
    }

    /// Switches the source install on or off. The app's own service is not switched off this way,
    /// and the source install is never started while the app's service is the live one.
    public func setEnabled(_ enabled: Bool) throws {
        let context = try context()
        guard !context.isBundled else { throw LaunchAgentControlError.runsFromApp }
        let controller = try makeController()
        if enabled {
            // Registered or not, a running app service means a second one must not start.
            if (try? controller.isLoaded(label: Self.bundledLabel)) == true {
                throw LaunchAgentControlError.appServiceRunning
            }
            try controller.enable()
        } else {
            try controller.disable()
        }
    }

    /// Unloads and disables only the old source install, leaving the app's service and the shared
    /// paused and enabled state alone, so the app's service keeps syncing.
    public func disableSourceInstall() throws {
        do {
            try makeController().disable()
        } catch LaunchAgentControlError.operationFailed {
            throw LaunchAgentControlError.sourceInstallStillOn
        }
    }

    /// Turns automatic sync on, like `calopod agent enable`. When the app's service is the live one it
    /// is started again if it is not running, and nothing happens when it already is.
    public func enable() async throws {
        let context = try context()
        guard context.isBundled else { return try setEnabled(true) }
        let loaded = (try? makeController().isLoaded(label: Self.bundledLabel)) ?? false
        if !loaded { try await reregisterBundled() }
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
            try doctorReport(
                snapshot: context.snapshot, environment: context.environment,
                usesBundled: context.isBundled, sourceLoaded: context.sourceLoaded)
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
        appFailureMessage(error)
    }
}
#endif
