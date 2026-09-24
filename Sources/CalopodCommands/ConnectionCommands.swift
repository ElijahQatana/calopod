import ArgumentParser

public enum ConnectionProvider: String, CaseIterable, ExpressibleByArgument, Sendable {
    case eventkit
    case google
    case ics
    case microsoft
}

public struct ConnectionCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "connection",
        abstract: "Manage calendar account connections.",
        subcommands: [
            ConnectionAddCommand.self,
            ConnectionListCommand.self,
            ConnectionInspectCommand.self,
            ConnectionDisableCommand.self,
            ConnectionRemoveCommand.self,
        ],
        defaultSubcommand: ConnectionListCommand.self
    )

    public init() {}
}

public struct ConnectionAddCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "add")

    @Argument(help: "Provider name: google, microsoft, eventkit, or ics.")
    public var provider: ConnectionProvider

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "connection.add",
            payload: CommandPayload(
                status: "unavailable",
                message: "The \(provider.rawValue) connection adapter is not available yet. No change was made."
            ),
            format: output.format
        )
        throw ExitCode(CalopodExitCode.unavailable.rawValue)
    }
}

public struct ConnectionListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "connection.list",
            payload: CommandPayload(
                status: "ok",
                message: "No Connections are configured.",
                count: 0
            ),
            format: output.format
        )
    }
}

public struct ConnectionInspectCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "inspect")

    @Argument(help: "Logical Connection identifier.")
    public var connectionID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try unavailable(command: "connection.inspect", output: output)
    }
}

public struct ConnectionDisableCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "disable")

    @Argument(help: "Logical Connection identifier.")
    public var connectionID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try unavailable(command: "connection.disable", output: output)
    }
}

public struct ConnectionRemoveCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "remove")

    @Argument(help: "Logical Connection identifier.")
    public var connectionID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try unavailable(command: "connection.remove", output: output)
    }
}

private func unavailable(command: String, output: OutputOptions) throws {
    try OutputRenderer.write(
        command: command,
        payload: CommandPayload(
            status: "unavailable",
            message: "Connection persistence is not available yet. No change was made."
        ),
        format: output.format
    )
    throw ExitCode(CalopodExitCode.unavailable.rawValue)
}
