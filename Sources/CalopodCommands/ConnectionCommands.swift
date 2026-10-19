import ArgumentParser
import CalopodEventKit
import CalopodProviders
import CalopodStore

public enum ConnectionProvider: String, CaseIterable, ExpressibleByArgument, Sendable {
    case eventkit
    case google
    case ics
    case mac
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

/// Adds a Connection. For `mac` it requests Calendar access and lists calendars in one step.
public struct ConnectionAddCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "add")

    @Argument(help: "Provider name: mac, google, microsoft, eventkit, or ics.")
    public var provider: ConnectionProvider

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        guard provider == .google
                || provider == .microsoft
                || provider == .eventkit
                || provider == .mac else {
            try OutputRenderer.write(
                command: "connection.add",
                payload: CommandPayload(
                    status: "unavailable",
                    message: "The \(provider.rawValue) connection adapter is not available yet. No change was made."
                ),
                format: output.format,
                showIDs: output.ids
            )
            throw ExitCode(CalopodExitCode.unavailable.rawValue)
        }

        #if os(macOS)
        do {
            let connection: StoredConnection
            switch provider {
            case .google:
                connection = try await CommandEnvironment.googleService().authorize(
                    using: LoopbackBrowserAuthorizationSession()
                )
            case .microsoft:
                connection = try await CommandEnvironment.microsoftService().authorize(
                    using: LoopbackBrowserAuthorizationSession(
                        redirectHost: "localhost",
                        callbackPath: "/"
                    )
                )
            case .eventkit, .mac:
                let runner = try EventKitHostRunner()
                let permission = try runner.requestPermission()
                guard permission.status == .fullAccess, permission.errorCode == nil else {
                    throw CalendarAccessDeniedError.make(helper: runner.hostURL, status: permission.status)
                }
                let response = try runner.perform(EventKitHostRequest(operation: .calendars))
                guard response.status == .fullAccess, response.errorCode == nil else {
                    throw CalendarAccessDeniedError.make(helper: runner.hostURL, status: response.status)
                }
                connection = try CommandEnvironment.eventKitService().connect(
                    calendars: response.calendars
                )
            case .ics:
                throw ExitCode(CalopodExitCode.unavailable.rawValue)
            }
            let calendars = try await refreshCalendars(for: connection)
            try OutputRenderer.write(
                command: "connection.add",
                payload: CommandPayload(
                    status: "ok",
                    message: "Connected \(connection.displayLabel ?? connection.provider).",
                    count: calendars.count,
                    items: [
                        CommandItem(
                            id: connection.id,
                            kind: connection.provider,
                            label: connection.displayLabel
                        )
                    ]
                ),
                format: output.format,
                showIDs: output.ids
            )
        } catch {
            try failCommand(error, format: output.format)
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
            let repository = try CommandEnvironment.repository()
            let connections = try repository.connections()
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
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
        } catch {
            try failCommand(error, format: output.format)
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
            try disconnect(connection)
            try OutputRenderer.write(
                command: "connection.remove",
                payload: CommandPayload(status: "ok", message: "Removed the Connection."),
                format: output.format,
                showIDs: output.ids
            )
        } catch {
            try failCommand(error, format: output.format)
        }
    }
}

// `inspect` and `disable` are declared so the help text is complete, but they report "unavailable"
// until they are built.
private func unavailable(command: String, output: OutputOptions) throws {
    try OutputRenderer.write(
        command: command,
        payload: CommandPayload(
            status: "unavailable",
            message: "Connection persistence is not available yet. No change was made."
        ),
        format: output.format,
        showIDs: output.ids
    )
    throw ExitCode(CalopodExitCode.unavailable.rawValue)
}
