import ArgumentParser
import CalopodProviders
import CalopodStore

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

public struct ConnectionAddCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "add")

    @Argument(help: "Provider name: google, microsoft, eventkit, or ics.")
    public var provider: ConnectionProvider

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        guard provider == .google else {
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

        #if os(macOS)
        do {
            let service = try CommandEnvironment.googleService()
            let connection = try await service.authorize(using: LoopbackBrowserAuthorizationSession())
            let calendars = try await service.refreshCalendars(connectionID: connection.id)
            try OutputRenderer.write(
                command: "connection.add",
                payload: CommandPayload(
                    status: "ok",
                    message: "Connected Google Calendar.",
                    count: calendars.count,
                    items: [
                        CommandItem(
                            id: connection.id,
                            kind: connection.provider,
                            label: connection.displayLabel
                        )
                    ]
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        throw commandFailure(CommandEnvironmentError.unsupportedPlatform)
        #endif
    }
}

public struct ConnectionListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let connections = try CommandEnvironment.repository().connections()
            try OutputRenderer.write(
                command: "connection.list",
                payload: CommandPayload(
                    status: "ok",
                    message: connections.isEmpty ? "No Connections are configured." : "Configured Connections.",
                    count: connections.count,
                    items: connections.map {
                        CommandItem(id: $0.id, kind: $0.provider, label: $0.displayLabel)
                    }
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
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
        do {
            let repository = try CommandEnvironment.repository()
            guard let connection = try repository.connection(id: connectionID) else {
                throw ValidationError("Connection '\(connectionID)' was not found.")
            }
            guard connection.provider == "google" else {
                try unavailable(command: "connection.remove", output: output)
                return
            }
            try CommandEnvironment.googleService(requireClientID: false).disconnect(
                connectionID: connectionID
            )
            try OutputRenderer.write(
                command: "connection.remove",
                payload: CommandPayload(status: "ok", message: "Removed the Google Connection."),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
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
