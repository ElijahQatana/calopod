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

/// Connects a new Connection. For `mac`/`eventkit` this is the normal
/// permission and calendar-discovery entry point: it requests Calendar
/// access through the EventKit host, then immediately lists calendars while
/// access is confirmed, rather than requiring a separate discovery step.
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
                    throw ProviderFailure.permissionDenied
                }
                let response = try runner.perform(EventKitHostRequest(operation: .calendars))
                guard response.status == .fullAccess, response.errorCode == nil else {
                    throw ProviderFailure.permissionDenied
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
            try disconnect(connection)
            try OutputRenderer.write(
                command: "connection.remove",
                payload: CommandPayload(status: "ok", message: "Removed the Connection."),
                format: output.format,
                showIDs: output.ids
            )
        } catch {
            try failCommand(error)
        }
    }
}

// `inspect` and `disable` are declared as real subcommands (so the command
// tree and its help text already reflect the intended shape) but report
// "unavailable" rather than doing nothing silently, since the persistence
// they'd need doesn't exist yet.
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
