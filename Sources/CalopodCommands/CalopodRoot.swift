import ArgumentParser

/// The top-level `calopod` command and its full subcommand tree. This is the
/// one place that assembles the command surface, so the list here is the
/// authoritative answer to "what can the CLI do."
public struct CalopodRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calopod",
        abstract: "One schedule. Many calendars.",
        version: "0.1.1",
        subcommands: [
            ConnectionCommand.self,
            CalendarsCommand.self,
            ArmCommand.self,
            MainCommand.self,
            EventsCommand.self,
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
