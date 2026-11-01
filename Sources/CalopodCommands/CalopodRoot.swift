import ArgumentParser

/// The top-level `calopod` command and its subcommands.
public struct CalopodRoot: AsyncParsableCommand {
    public static let version = "1.5.0"

    public static let configuration = CommandConfiguration(
        commandName: "calopod",
        abstract: "One schedule. Many calendars.",
        version: version,
        subcommands: [
            ConnectionCommand.self,
            CalendarsCommand.self,
            ArmCommand.self,
            MainCommand.self,
            EventsCommand.self,
            JoinCommand.self,
            InboxCommand.self,
            NotificationsCommand.self,
            AvailabilityCommand.self,
            HoursCommand.self,
            IPhoneCommand.self,
            UpdateCommand.self,
            SyncCommand.self,
            DoctorCommand.self,
            AgentCommand.self,
            SupportCommand.self,
        ]
    )

    public init() {}
}
