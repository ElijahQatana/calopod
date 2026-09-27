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
