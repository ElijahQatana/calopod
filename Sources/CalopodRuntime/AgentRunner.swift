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

    public init(
        environment: CalopodRuntimeEnvironment,
        schedule: AgentSchedule,
        now: @escaping @Sendable () -> Date = Date.init,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.environment = environment
        self.schedule = schedule
        self.now = now
        self.randomUnit = randomUnit
        self.sleep = sleep
    }

    public func runOnce(ignorePause: Bool = false) async -> AgentRunReport {
        do {
            if !ignorePause, try environment.repository().agentControl().isPaused {
                return AgentRunReport(status: "paused")
            }
            let window = try schedule.window(containing: now())
            let result = try await SyncEngine(environment: environment).run(
                SyncRequest(mode: .apply, window: window),
                trigger: .automatic
            )
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

    public func runUntilCancelled(
        report: @escaping @Sendable (AgentRunReport) -> Void
    ) async {
        while !Task.isCancelled {
            let result = await runOnce()
            guard !Task.isCancelled else { return }
            report(result)
            do {
                try await sleep(schedule.delay(randomUnit: randomUnit()))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}
