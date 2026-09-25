import ArgumentParser

public struct CalopodRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calopod",
        abstract: "One schedule. Many calendars.",
        version: "0.1.0",
        subcommands: [
            ConnectionCommand.self,
            CalendarsCommand.self,
            ArmCommand.self,
            EventsCommand.self,
            AvailabilityCommand.self,
            SyncCommand.self,
            DoctorCommand.self,
            AgentCommand.self,
        ]
    )

    public init() {}
}
