import ArgumentParser
import CalopodStore
import CalopodSync

public struct MainCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "main",
        abstract: "Configure the full-detail Main calendar.",
        subcommands: [
            MainConfigureCommand.self,
            MainInspectCommand.self,
        ],
        defaultSubcommand: MainInspectCommand.self
    )

    public init() {}
}

/// Creates the Main calendar Arm. `ArmConfigurationService` enforces one Main calendar and the Full
/// details Rule.
public struct MainConfigureCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Designate one writable target as the Main calendar."
    )

    @Option(name: .long, help: "Selected source calendar identifier. Repeat for multiple sources.")
    public var source: [String] = []

    @Option(name: .long, help: "Writable Main calendar identifier.")
    public var target: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let arm = try ArmConfigurationService(
                repository: repository
            ).configureMainCalendar(
                sourceBindingIDs: source,
                targetBindingID: target
            )
            try OutputRenderer.write(
                command: "main.configure",
                payload: CommandPayload(
                    status: "ok",
                    message: "Configured the Main calendar. No calendar events were changed.",
                    count: 1,
                    items: [mainItem(arm)]
                ),
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
        } catch let error as ArmConfigurationError {
            try failCommand(ValidationError(error.description))
        } catch {
            try failCommand(error)
        }
    }
}

public struct MainInspectCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "inspect")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let main = try repository.arms().first(where: \.isMain)
            try OutputRenderer.write(
                command: "main.inspect",
                payload: CommandPayload(
                    status: "ok",
                    message: main == nil
                        ? "No Main calendar is configured."
                        : "Configured Main calendar.",
                    count: main == nil ? 0 : 1,
                    items: main.map { [mainItem($0)] } ?? []
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

private func mainItem(_ arm: StoredArm) -> CommandItem {
    CommandItem(
        id: arm.id,
        kind: "main-calendar",
        label: arm.displayName,
        sourceIDs: arm.sourceBindingIDs,
        targetID: arm.targetBindingID,
        rule: arm.ruleMode.rawValue,
        enabled: arm.isEnabled
    )
}
