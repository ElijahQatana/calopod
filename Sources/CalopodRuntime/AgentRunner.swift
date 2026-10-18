import CalopodDomain
import Foundation

public struct AgentSchedule: Equatable, Sendable {
    public let interval: TimeInterval
    public let maximumJitter: TimeInterval
    public let lookbackDays: Int
    public let horizonDays: Int

    public init(
        interval: TimeInterval,
        maximumJitter: TimeInterval,
        lookbackDays: Int,
        horizonDays: Int
    ) throws {
        guard interval > 0,
              maximumJitter >= 0,
              lookbackDays >= 0,
              horizonDays > 0 else {
            throw CalopodRuntimeError.invalidConfiguration("agent-schedule")
        }
        self.interval = interval
        self.maximumJitter = maximumJitter
        self.lookbackDays = lookbackDays
        self.horizonDays = horizonDays
    }

    public init(environment: [String: String]) throws {
        guard let interval = environment["CALOPOD_AGENT_INTERVAL_SECONDS"].flatMap(Double.init),
              let maximumJitter = environment["CALOPOD_AGENT_JITTER_SECONDS"].flatMap(Double.init),
              let lookbackDays = environment["CALOPOD_AGENT_LOOKBACK_DAYS"].flatMap(Int.init),
              let horizonDays = environment["CALOPOD_AGENT_HORIZON_DAYS"].flatMap(Int.init) else {
            throw CalopodRuntimeError.invalidConfiguration("agent-schedule")
        }
        try self.init(
            interval: interval,
            maximumJitter: maximumJitter,
            lookbackDays: lookbackDays,
            horizonDays: horizonDays
        )
    }

    public func window(
        containing date: Date,
        calendar: Calendar = .current
    ) throws -> SyncWindow {
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -lookbackDays, to: day),
              let end = calendar.date(byAdding: .day, value: horizonDays + 1, to: day) else {
            throw CalopodRuntimeError.invalidConfiguration("agent-window")
        }
        return try SyncWindow(start: start, end: end)
    }

    public func delay(randomUnit: Double) -> TimeInterval {
        interval + maximumJitter * min(max(randomUnit, 0), 1)
    }
}

/// What a calendar read has to span so the app can draw this week and the next without a gap:
/// a week back, two weeks ahead. Every reader that records coverage (the agent, a manual sync,
/// Refresh calendars, `calopod inbox refresh`) uses it, so they agree about what "read" means.
public enum CalendarReadWindow {
    public static let lookbackDays = 7
    public static let horizonDays = 14

    /// The tracked read window around a date, in whole local days.
    public static func containing(_ date: Date, calendar: Calendar = .current) throws -> SyncWindow {
        try covering(nil, around: date, calendar: calendar)
    }

    /// The tracked window, widened if needed to also include `window`.
    public static func covering(
        _ window: SyncWindow?, around date: Date = Date(), calendar: Calendar = .current
    ) throws -> SyncWindow {
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -lookbackDays, to: day),
              let end = calendar.date(byAdding: .day, value: horizonDays + 1, to: day) else {
            throw CalopodRuntimeError.invalidConfiguration("read-window")
        }
        return try SyncWindow(start: min(start, window?.start ?? start), end: max(end, window?.end ?? end))
    }
}

/// An interval from the Mac app that replaces the installed one. A missing or invalid file is ignored.
public struct AgentScheduleOverride: Codable, Equatable, Sendable {
    public static let minimumIntervalSeconds = 60
    public static let maximumIntervalSeconds = 86_400

    public let intervalSeconds: Int

    public init(intervalSeconds: Int) throws {
        guard (Self.minimumIntervalSeconds...Self.maximumIntervalSeconds).contains(intervalSeconds) else {
            throw CalopodRuntimeError.invalidConfiguration("agent-schedule")
        }
        self.intervalSeconds = intervalSeconds
    }

    public static func load(from location: CalopodStateLocation) -> AgentScheduleOverride? {
        guard let data = try? Data(contentsOf: location.scheduleOverrideURL),
              let decoded = try? JSONDecoder().decode(AgentScheduleOverride.self, from: data),
              (minimumIntervalSeconds...maximumIntervalSeconds).contains(decoded.intervalSeconds) else {
            return nil
        }
        return decoded
    }

    public func save(to location: CalopodStateLocation) throws {
        try location.prepareDirectory()
        let data = try JSONEncoder().encode(self)
        let temporary = location.scheduleOverrideURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporary)
        try PrivateFiles.createFile(at: temporary, contents: data)
        _ = try FileManager.default.replaceItemAt(location.scheduleOverrideURL, withItemAt: temporary)
    }

    public static func clear(from location: CalopodStateLocation) {
        try? FileManager.default.removeItem(at: location.scheduleOverrideURL)
    }
}

extension AgentSchedule {
    public func applying(_ override: AgentScheduleOverride?) -> AgentSchedule {
        guard let override,
              let replaced = try? AgentSchedule(
                  interval: Double(override.intervalSeconds),
                  maximumJitter: maximumJitter,
                  lookbackDays: lookbackDays,
                  horizonDays: horizonDays
              ) else {
            return self
        }
        return replaced
    }
}

public struct AgentRunReport: Codable, Equatable, Sendable {
    public let command: String
    public let status: String
    public let planned: Int
    public let applied: Int
    public let creates: Int
    public let updates: Int
    public let removals: Int
    public let repairs: Int
    public let noOps: Int
    public let warningCount: Int
    public let failureCategory: String?

    public init(
        status: String,
        planned: Int = 0,
        applied: Int = 0,
        creates: Int = 0,
        updates: Int = 0,
        removals: Int = 0,
        repairs: Int = 0,
        noOps: Int = 0,
        warningCount: Int = 0,
        failureCategory: String? = nil
    ) {
        command = "agent.run"
        self.status = status
        self.planned = planned
        self.applied = applied
        self.creates = creates
        self.updates = updates
        self.removals = removals
        self.repairs = repairs
        self.noOps = noOps
        self.warningCount = warningCount
        self.failureCategory = failureCategory
    }
}

public struct CalopodAgentRunner: Sendable {
    private let environment: CalopodRuntimeEnvironment
    private let schedule: AgentSchedule
    private let now: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let runSync: @Sendable (SyncRequest) async throws -> SyncExecutionResult
    private let scheduleCheckSeconds: Double

    public init(
        environment: CalopodRuntimeEnvironment,
        schedule: AgentSchedule,
        now: @escaping @Sendable () -> Date = Date.init,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.init(
            environment: environment,
            schedule: schedule,
            now: now,
            randomUnit: randomUnit,
            sleep: sleep
        ) { request in
            try await SyncEngine(environment: environment).run(
                request,
                trigger: .automatic
            )
        }
    }

    init(
        environment: CalopodRuntimeEnvironment,
        schedule: AgentSchedule,
        now: @escaping @Sendable () -> Date,
        randomUnit: @escaping @Sendable () -> Double,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        runSync: @escaping @Sendable (SyncRequest) async throws -> SyncExecutionResult,
        scheduleCheckSeconds: Double = 15
    ) {
        self.scheduleCheckSeconds = scheduleCheckSeconds
        self.environment = environment
        self.schedule = schedule
        self.now = now
        self.randomUnit = randomUnit
        self.sleep = sleep
        self.runSync = runSync
    }

    public func runOnce(ignorePause: Bool = false) async -> AgentRunReport {
        do {
            if !ignorePause, try environment.repository().agentControl().isPaused {
                return AgentRunReport(status: "paused")
            }
            let window = try schedule.window(containing: now())
            let result = try await runSync(SyncRequest(mode: .apply, window: window))
            return AgentRunReport(
                status: result.status,
                planned: result.items.count,
                applied: result.appliedCount,
                creates: result.items.filter { $0.action == .create }.count,
                updates: result.items.filter { $0.action == .update }.count,
                removals: result.items.filter { $0.action == .remove }.count,
                repairs: result.items.filter { $0.action == .repair }.count,
                noOps: result.noOpCount,
                warningCount: result.warnings.count
            )
        } catch is CancellationError {
            return AgentRunReport(status: "interrupted")
        } catch {
            let isBusy = (error as? CalopodRuntimeError) == .busy
            return AgentRunReport(
                status: isBusy ? "busy" : "failed",
                failureCategory: syncFailureCategory(error)
            )
        }
    }

    /// Ends the wait early when the override changes, so a new interval applies within seconds.
    private func sleepUnlessScheduleChanges() async throws {
        let baseline = AgentScheduleOverride.load(from: environment.stateLocation)
        let delay = schedule.applying(baseline).delay(randomUnit: randomUnit())
        let location = environment.stateLocation
        let checkSeconds = scheduleCheckSeconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await sleep(delay) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(checkSeconds))
                    if AgentScheduleOverride.load(from: location) != baseline { return }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    public func runUntilCancelled(
        report: @escaping @Sendable (AgentRunReport) -> Void
    ) async {
        while !Task.isCancelled {
            let result = await runOnce()
            guard !Task.isCancelled else { return }
            report(result)
            do {
                try await sleepUnlessScheduleChanges()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}
