import ArgumentParser
import CalopodDomain
import CalopodSync

public struct SyncCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Plan or run synchronization for a configured range."
    )

    @Flag(name: .long, help: "Plan changes without writing provider data.")
    public var dryRun = false

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .none)
        let mode: SyncMode = dryRun ? .dryRun : .apply
        let summary = try await SyncEngine().run(
            SyncRequest(mode: mode, window: resolved?.window)
        )

        try OutputRenderer.write(
            command: "sync",
            payload: CommandPayload(
                status: "ok",
                message: "The sync shell completed with no provider operations.",
                count: summary.plannedOperationCount,
                range: resolved.map(RangeOutput.init),
                mode: summary.mode.rawValue
            ),
            warnings: ["Provider writes are not available in the read-only milestone."],
            format: output.format
        )
    }
}

public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect local configuration and provider health."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "doctor",
            payload: CommandPayload(
                status: "ok",
                message: "The command shell and shared core are available."
            ),
            format: output.format
        )
    }
}

public struct AgentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Inspect or run the local background agent."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "agent",
            payload: CommandPayload(
                status: "unavailable",
                message: "Agent installation and control are planned for the background-service milestone."
            ),
            format: output.format
        )
        throw ExitCode(CalopodExitCode.unavailable.rawValue)
    }
}
