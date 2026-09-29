import ArgumentParser
import CalopodRuntime
import Foundation

public struct AgentCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Control and inspect automatic synchronization.",
        subcommands: [
            AgentEnableCommand.self,
            AgentDisableCommand.self,
            AgentPauseCommand.self,
            AgentResumeCommand.self,
            AgentIntervalCommand.self,
            AgentRunNowCommand.self,
            AgentStatusCommand.self,
        ]
    )

    public init() {}
}

public struct AgentEnableCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable and start automatic synchronization."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            try controller.enable()
            try writeAgentControlResult(
                command: "agent.enable",
                message: "Automatic synchronization is enabled.",
                controller: controller,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentDisableCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop and disable automatic synchronization."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            try controller.disable()
            try writeAgentControlResult(
                command: "agent.disable",
                message: "Automatic synchronization is disabled.",
                controller: controller,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentPauseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause scheduled synchronization without disabling the service."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            let environment = try installedAgentEnvironment(controller: controller)
            try environment.repository().setAgentPaused(true)
            try controller.restartIfEnabled()
            try writeAgentControlResult(
                command: "agent.pause",
                message: "Automatic synchronization is paused.",
                controller: controller,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentResumeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume scheduled synchronization."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            let environment = try installedAgentEnvironment(controller: controller)
            try environment.repository().setAgentPaused(false)
            try controller.restartIfEnabled()
            try writeAgentControlResult(
                command: "agent.resume",
                message: "Automatic synchronization is resumed.",
                controller: controller,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentIntervalCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "interval",
        abstract: "Change the installed automatic-sync interval."
    )

    @Option(name: .long, help: "Seconds between scheduled runs.")
    public var seconds: Int

    @Option(name: .long, help: "Maximum random delay added to each interval.")
    public var jitterSeconds: Int?

    @Option(name: .long, help: "Days before today included in each automatic run.")
    public var lookbackDays: Int?

    @Option(name: .long, help: "Days after today included in each automatic run.")
    public var horizonDays: Int?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func validate() throws {
        guard seconds > 0 else {
            throw ValidationError("--seconds must be greater than zero.")
        }
        if let jitterSeconds, jitterSeconds < 0 {
            throw ValidationError("--jitter-seconds must not be negative.")
        }
        if let lookbackDays, lookbackDays < 0 {
            throw ValidationError("--lookback-days must not be negative.")
        }
        if let horizonDays, horizonDays <= 0 {
            throw ValidationError("--horizon-days must be greater than zero.")
        }
    }

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            try controller.updateSchedule(
                intervalSeconds: seconds,
                jitterSeconds: jitterSeconds,
                lookbackDays: lookbackDays,
                horizonDays: horizonDays
            )
            try writeAgentControlResult(
                command: "agent.interval",
                message: "The automatic-sync interval was updated.",
                controller: controller,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentRunNowCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run-now",
        abstract: "Run one bounded synchronization immediately."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            let environment = try installedAgentEnvironment(controller: controller)
            let configuration = try requireInstalledConfiguration(controller)
            let report = await CalopodAgentRunner(
                environment: environment,
                schedule: try AgentSchedule(environment: configuration.environment)
            ).runOnce(ignorePause: true)
            try OutputRenderer.write(
                command: "agent.run-now",
                payload: CommandPayload(
                    status: report.status,
                    message: agentRunMessage(status: report.status),
                    failureCategory: report.failureCategory,
                    planned: report.planned,
                    applied: report.applied,
                    creates: report.creates,
                    updates: report.updates,
                    removals: report.removals,
                    repairs: report.repairs,
                    noOps: report.noOps,
                    warningCount: report.warningCount
                ),
                format: output.format
            )
            switch report.status {
            case "ok": return
            case "busy": throw ExitCode(CalopodExitCode.temporaryFailure.rawValue)
            default: throw ExitCode(CalopodExitCode.unavailable.rawValue)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct AgentStatusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show automatic-sync state and recent health."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            try OutputRenderer.write(
                command: "agent.status",
                payload: try agentStatusPayload(controller: controller),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

#if os(macOS)
func installedAgentEnvironment(
    controller: LaunchAgentController
) throws -> CalopodRuntimeEnvironment {
    guard let configuration = try controller.snapshot().configuration else {
        throw LaunchAgentControlError.notInstalled
    }
    return try CalopodRuntimeEnvironment(
        variables: configuration.environment,
        stateLocation: CalopodStateLocation(environment: configuration.environment),
        executableURL: configuration.programURL
    )
}

func agentStatusPayload(
    controller: LaunchAgentController,
    now: Date = Date()
) throws -> CommandPayload {
    let snapshot = try controller.snapshot()
    guard let configuration = snapshot.configuration else {
        return CommandPayload(
            status: "not-installed",
            message: "The automatic-sync service is not installed.",
            installed: false,
            enabled: false,
            paused: false,
            runState: "stopped",
            stateReady: false
        )
    }

    let stateReady = FileManager.default.fileExists(atPath: configuration.stateURL.path)
    var paused = false
    var lastSuccessAgeSeconds: Int?
    var failureCategory: String?
    if stateReady {
        let repository = try installedAgentEnvironment(controller: controller).repository()
        paused = try repository.agentControl().isPaused
        if let success = try repository.latestSuccessfulSyncRun(trigger: "automatic") {
            let reference = success.finishedAt ?? success.startedAt
            lastSuccessAgeSeconds = max(0, Int(now.timeIntervalSince(reference)))
        }
        if let latest = try repository.latestSyncRun(trigger: "automatic"),
           latest.status == "failed" || latest.status == "interrupted" {
            failureCategory = genericFailureCategory(latest.errorCode)
        }
    }

    let enabled = !snapshot.disabled
    let status: String
    let message: String
    if !enabled {
        status = "disabled"
        message = "Automatic synchronization is disabled."
    } else if paused {
        status = "paused"
        message = "Automatic synchronization is paused."
    } else if failureCategory != nil {
        status = "failed"
        message = "The most recent automatic synchronization failed."
    } else if snapshot.loaded {
        status = "ok"
        message = "Automatic synchronization is running."
    } else {
        status = "stopped"
        message = "Automatic synchronization is enabled but not running."
    }

    return CommandPayload(
        status: status,
        message: message,
        installed: true,
        enabled: enabled,
        paused: paused,
        runState: snapshot.loaded ? "running" : "stopped",
        stateReady: stateReady,
        intervalSeconds: configuration.intervalSeconds,
        jitterSeconds: configuration.jitterSeconds,
        lookbackDays: configuration.lookbackDays,
        horizonDays: configuration.horizonDays,
        lastSuccessAgeSeconds: lastSuccessAgeSeconds,
        failureCategory: failureCategory
    )
}

private func requireInstalledConfiguration(
    _ controller: LaunchAgentController
) throws -> AgentServiceConfiguration {
    guard let configuration = try controller.snapshot().configuration else {
        throw LaunchAgentControlError.notInstalled
    }
    return configuration
}

private func agentRunMessage(status: String) -> String {
    switch status {
    case "ok": "The automatic synchronization run completed."
    case "busy": "Another synchronization run already holds the process lock."
    case "interrupted": "The automatic synchronization run was interrupted."
    default: "The automatic synchronization run failed."
    }
}

private func writeAgentControlResult(
    command: String,
    message: String,
    controller: LaunchAgentController,
    format: OutputFormat
) throws {
    let snapshot = try controller.snapshot()
    let paused: Bool?
    if let configuration = snapshot.configuration,
       FileManager.default.fileExists(atPath: configuration.stateURL.path) {
        paused = try installedAgentEnvironment(controller: controller)
            .repository()
            .agentControl()
            .isPaused
    } else {
        paused = false
    }
    try OutputRenderer.write(
        command: command,
        payload: CommandPayload(
            status: "ok",
            message: message,
            installed: snapshot.installed,
            enabled: snapshot.installed && !snapshot.disabled,
            paused: paused,
            runState: snapshot.loaded ? "running" : "stopped",
            stateReady: snapshot.configuration.map {
                FileManager.default.fileExists(atPath: $0.stateURL.path)
            },
            intervalSeconds: snapshot.configuration?.intervalSeconds,
            jitterSeconds: snapshot.configuration?.jitterSeconds,
            lookbackDays: snapshot.configuration?.lookbackDays,
            horizonDays: snapshot.configuration?.horizonDays
        ),
        format: format
    )
}
#endif
