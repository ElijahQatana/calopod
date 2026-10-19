import ArgumentParser

/// The top-level `calopod` command and its subcommands.
public struct CalopodRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calopod",
        abstract: "One schedule. Many calendars.",
        version: "1.0.0",
        subcommands: [
            ConnectionCommand.self,
            CalendarsCommand.self,
            ArmCommand.self,
            MainCommand.self,
            EventsCommand.self,
            JoinCommand.self,
            InboxCommand.self,
            AvailabilityCommand.self,
            SyncCommand.self,
            DoctorCommand.self,
            AgentCommand.self,
            SupportCommand.self,
        ]
    )

    public init() {}
}
