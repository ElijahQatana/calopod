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

/// Changes an existing Arm's Rule or preferred writer. Deliberately separate
/// from `ArmAddCommand`: both operations are configuration-only (no
/// calendar write ever happens here), but updating an existing Arm and
/// creating a new one have different validation needs, so keeping them
/// distinct commands avoids one doing double duty.
public struct ArmUpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change an Arm name, Rule or preferred writer without writing calendar events."
    )

    @Argument(help: "Arm identifier.")
    public var armID: String

    @Option(name: .long, help: "Disclosure Rule: busy or full-details.")
    public var rule: ArmRuleArgument?

    @Flag(name: .customLong("prefer-current-device"), help: "Make this device the preferred writer.")
    public var preferCurrentDevice = false

    @Option(name: .long, help: "Private display name. Use an empty value to clear it.")
    public var name: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            guard name != nil || rule != nil || preferCurrentDevice else {
                throw ValidationError(
                    "Choose --name, --rule or --prefer-current-device."
                )
            }
            let repository = try CommandEnvironment.repository()
            let service = ArmConfigurationService(repository: repository)
            var arm: StoredArm
            if let rule {
                arm = try service.updateRule(armID: armID, ruleMode: rule.ruleMode)
            } else if let existing = try repository.arm(id: armID) {
                arm = existing
            } else {
                throw ArmConfigurationError.armNotFound(armID)
            }
            if let name {
                arm = try service.rename(armID: arm.id, name: name)
            }
            if preferCurrentDevice {
                arm = try service.preferCurrentDevice(armID: arm.id)
            }
            try OutputRenderer.write(
                command: "arm.update",
                payload: CommandPayload(
                    status: "ok",
                    message: "Updated the Arm configuration. No calendar events were changed.",
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

/// Creates a new Arm. All the actual safety checks (cycles, duplicate
/// routes, read-only targets, mismatched configurations) live in
/// `ArmConfigurationService.createArm`; this command's job is just to
/// collect the arguments and translate that service's typed errors into
/// user-facing messages.
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

    @Option(name: .long, help: "Private display name. Use an empty value to clear it.")
    public var name: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let arm = try ArmConfigurationService(repository: repository).createArm(
                sourceBindingIDs: source,
                targetBindingID: target,
                ruleMode: rule.ruleMode,
                name: name
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
        kind: arm.isMain ? "main-calendar" : "arm",
        label: arm.displayName,
        sourceIDs: arm.sourceBindingIDs,
        targetID: arm.targetBindingID,
        rule: arm.ruleMode.rawValue,
        enabled: arm.isEnabled
    )
}
