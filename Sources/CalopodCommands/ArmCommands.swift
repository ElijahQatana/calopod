import ArgumentParser
import CalopodDomain
import CalopodStore
import CalopodSync

public enum ArmRuleArgument: String, CaseIterable, ExpressibleByArgument, Sendable {
    case busy
    case fullDetails = "full-details"

    var ruleMode: ArmRuleMode {
        switch self {
        case .busy: .busy
        case .fullDetails: .fullDetails
        }
    }
}

public struct ArmCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "arm",
        abstract: "Manage sync and publish relationships.",
        subcommands: [
            ArmAddCommand.self,
            ArmListCommand.self,
            ArmInspectCommand.self,
            ArmUpdateCommand.self,
            ArmDisableCommand.self,
            ArmRemoveCommand.self,
        ],
        defaultSubcommand: ArmListCommand.self
    )

    public init() {}
}

public struct ArmUpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change an Arm Rule without writing calendar events."
    )

    @Argument(help: "Arm identifier.")
    public var armID: String

    @Option(name: .long, help: "Disclosure Rule: busy or full-details.")
    public var rule: ArmRuleArgument

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let arm = try ArmConfigurationService(
                repository: CommandEnvironment.repository()
            ).updateRule(armID: armID, ruleMode: rule.ruleMode)
            try OutputRenderer.write(
                command: "arm.update",
                payload: CommandPayload(
                    status: "ok",
                    message: "Updated the Arm Rule. No calendar events were changed.",
                    count: 1,
                    items: [armItem(arm)]
                ),
                format: output.format
            )
        } catch let error as ArmConfigurationError {
            try failCommand(ValidationError(error.description))
        } catch {
            try failCommand(error)
        }
    }
}

public struct ArmAddCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create an Arm without writing calendar events."
    )

    @Option(name: .long, help: "Selected source calendar identifier. Repeat for multiple sources.")
    public var source: [String] = []

    @Option(name: .long, help: "Writable target calendar identifier.")
    public var target: String

    @Option(name: .long, help: "Disclosure Rule: busy or full-details. (default: busy)")
    public var rule: ArmRuleArgument = .busy

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let arm = try ArmConfigurationService(repository: repository).createArm(
                sourceBindingIDs: source,
                targetBindingID: target,
                ruleMode: rule.ruleMode
            )
            try OutputRenderer.write(
                command: "arm.add",
                payload: CommandPayload(
                    status: "ok",
                    message: "Created the Arm. No calendar events were changed.",
                    count: 1,
                    items: [armItem(arm)]
                ),
                format: output.format
            )
        } catch let error as ArmConfigurationError {
            try failCommand(ValidationError(error.description))
        } catch {
            try failCommand(error)
        }
    }
}

public struct ArmListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let arms = try CommandEnvironment.repository().arms()
            try OutputRenderer.write(
                command: "arm.list",
                payload: CommandPayload(
                    status: "ok",
                    message: arms.isEmpty ? "No Arms are configured." : "Configured Arms.",
                    count: arms.count,
                    items: arms.map(armItem)
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

public struct ArmInspectCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "inspect")

    @Argument(help: "Arm identifier.")
    public var armID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            guard let arm = try repository.arm(id: armID) else {
                throw ValidationError("Arm '\(armID)' was not found.")
            }
            try OutputRenderer.write(
                command: "arm.inspect",
                payload: CommandPayload(
                    status: "ok",
                    message: "Configured Arm.",
                    count: 1,
                    items: [armItem(arm)]
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

public struct ArmDisableCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "disable")

    @Argument(help: "Arm identifier.")
    public var armID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            guard let arm = try repository.setArmEnabled(id: armID, isEnabled: false) else {
                throw ValidationError("Arm '\(armID)' was not found.")
            }
            try OutputRenderer.write(
                command: "arm.disable",
                payload: CommandPayload(
                    status: "ok",
                    message: "Disabled the Arm. No calendar events were changed.",
                    count: 1,
                    items: [armItem(arm)]
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

public struct ArmRemoveCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "remove")

    @Argument(help: "Arm identifier.")
    public var armID: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            guard try repository.arm(id: armID) != nil else {
                throw ValidationError("Arm '\(armID)' was not found.")
            }
            try repository.removeArm(id: armID)
            try OutputRenderer.write(
                command: "arm.remove",
                payload: CommandPayload(
                    status: "ok",
                    message: "Removed the Arm. No calendar events were changed."
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func armItem(_ arm: StoredArm) -> CommandItem {
    CommandItem(
        id: arm.id,
        kind: "arm",
        sourceIDs: arm.sourceBindingIDs,
        targetID: arm.targetBindingID,
        rule: arm.ruleMode.rawValue,
        enabled: arm.isEnabled
    )
}
