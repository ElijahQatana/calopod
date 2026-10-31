import ArgumentParser
import CalopodDomain
import CalopodStore
import CalopodSync

public enum ArmRuleArgument: String, CaseIterable, ExpressibleByArgument, Sendable {
    case busy
    case label
    case fullDetails = "full-details"

    var ruleMode: ArmRuleMode {
        switch self {
        case .busy: .busy
        case .label: .label
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

/// Changes an Arm's name, Rule, filters, padding or preferred writer. Configuration only; never
/// writes to a calendar.
public struct ArmUpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change an Arm name, Rule, filters, padding or preferred writer without writing calendar events."
    )

    @Argument(help: "Arm identifier.")
    public var armID: String

    @Option(name: .long, help: "Disclosure Rule: busy, label or full-details.")
    public var rule: ArmRuleArgument?

    @Option(name: .long, help: "Fixed title for copies under the label Rule.")
    public var label: String?

    @Flag(name: .customLong("prefer-current-device"), help: "Make this device the preferred writer.")
    public var preferCurrentDevice = false

    @Option(name: .long, help: "Private display name. Use an empty value to clear it.")
    public var name: String?

    @Flag(inversion: .prefixedNo, help: "Leave out events you declined.")
    public var skipDeclined: Bool?

    @Flag(inversion: .prefixedNo, help: "Leave out all-day events.")
    public var skipAllDay: Bool?

    @Flag(inversion: .prefixedNo, help: "Leave out events with #dontclone in the title or notes.")
    public var skipDontclone: Bool?

    @Option(name: .long, help: "Minutes the copy starts before the event.")
    public var padBefore: Int?

    @Option(name: .long, help: "Minutes the copy ends after the event.")
    public var padAfter: Int?

    @Flag(inversion: .prefixedNo, help: "Pad only events with a location and no meeting link.")
    public var padInPersonOnly: Bool?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let changesPadding = padBefore != nil || padAfter != nil || padInPersonOnly != nil
            let changesFilters = skipDeclined != nil || skipAllDay != nil || skipDontclone != nil
            guard name != nil || rule != nil || label != nil || preferCurrentDevice || changesFilters || changesPadding else {
                throw ValidationError(
                    "Choose --name, --rule, --label, --prefer-current-device, a filter such as --skip-declined or padding such as --pad-before."
                )
            }
            let repository = try CommandEnvironment.repository()
            let service = ArmConfigurationService(repository: repository)
            var arm: StoredArm
            guard let existing = try repository.arm(id: armID) else {
                throw ArmConfigurationError.armNotFound(armID)
            }
            if rule != nil || label != nil {
                arm = try service.updateRule(
                    armID: armID, ruleMode: rule?.ruleMode ?? existing.ruleMode, label: label)
            } else {
                arm = existing
            }
            if let name {
                arm = try service.rename(armID: arm.id, name: name)
            }
            if changesFilters {
                arm = try service.updateFilters(
                    armID: arm.id,
                    filters: ArmFilters(
                        skipDeclined: skipDeclined ?? arm.filters.skipDeclined,
                        skipAllDay: skipAllDay ?? arm.filters.skipAllDay,
                        skipDontClone: skipDontclone ?? arm.filters.skipDontClone
                    )
                )
            }
            if changesPadding {
                arm = try service.updatePadding(
                    armID: arm.id,
                    padding: ArmPadding(
                        beforeMinutes: padBefore ?? arm.padding.beforeMinutes,
                        afterMinutes: padAfter ?? arm.padding.afterMinutes,
                        inPersonOnly: padInPersonOnly ?? arm.padding.inPersonOnly
                    )
                )
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

/// Creates an Arm. The safety checks live in `ArmConfigurationService.createArm`; this maps its
/// errors to messages.
public struct ArmAddCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create an Arm without writing calendar events."
    )

    @Option(name: .long, help: "Selected source calendar identifier. Repeat for multiple sources.")
    public var source: [String] = []

    @Option(name: .long, help: "Writable target calendar identifier.")
    public var target: String

    @Option(name: .long, help: "Disclosure Rule: busy, label or full-details. (default: busy)")
    public var rule: ArmRuleArgument = .busy

    @Option(name: .long, help: "Fixed title for copies under the label Rule.")
    public var label: String?

    @Option(name: .long, help: "Private display name. Use an empty value to clear it.")
    public var name: String?

    @Flag(help: "Leave out events you declined.")
    public var skipDeclined = false

    @Flag(help: "Leave out all-day events.")
    public var skipAllDay = false

    @Flag(help: "Leave out events with #dontclone in the title or notes.")
    public var skipDontclone = false

    @Option(name: .long, help: "Minutes the copy starts before the event.")
    public var padBefore: Int = 0

    @Option(name: .long, help: "Minutes the copy ends after the event.")
    public var padAfter: Int = 0

    @Flag(help: "Pad only events with a location and no meeting link.")
    public var padInPersonOnly = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let arm = try ArmConfigurationService(repository: repository).createArm(
                sourceBindingIDs: source,
                targetBindingID: target,
                ruleMode: rule.ruleMode,
                name: name,
                filters: ArmFilters(
                    skipDeclined: skipDeclined,
                    skipAllDay: skipAllDay,
                    skipDontClone: skipDontclone
                ),
                label: label,
                padding: ArmPadding(
                    beforeMinutes: padBefore, afterMinutes: padAfter, inPersonOnly: padInPersonOnly)
            )
            try OutputRenderer.write(
                command: "arm.add",
                payload: CommandPayload(
                    status: "ok",
                    message: "Created the Arm. No calendar events were changed.",
                    count: 1,
                    items: [armItem(arm)]
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

public struct ArmListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let repository = try CommandEnvironment.repository()
            let arms = try repository.arms()
            let health = try repository.armSyncHealths()
            try OutputRenderer.write(
                command: "arm.list",
                payload: CommandPayload(
                    status: "ok",
                    message: arms.isEmpty ? "No Arms are configured." : "Configured Arms.",
                    count: arms.count,
                    items: arms.map { armItem($0, status: ArmSyncStatus(arm: $0, health: health[$0.id])) }
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
                    items: [armItem(arm, status: ArmSyncStatus(arm: arm, health: try repository.armSyncHealth(armID: arm.id)))]
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
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
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
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func armItem(_ arm: StoredArm, status: ArmSyncStatus? = nil) -> CommandItem {
    CommandItem(
        id: arm.id,
        kind: arm.isMain ? "main-calendar" : "arm",
        label: arm.displayName,
        sourceIDs: arm.sourceBindingIDs,
        targetID: arm.targetBindingID,
        rule: arm.ruleMode.rawValue,
        enabled: arm.isEnabled,
        armLabel: arm.ruleMode == .label ? arm.label : nil,
        padding: arm.effectivePadding.isEmpty ? nil : paddingText(arm.effectivePadding),
        filters: arm.filters.isEmpty ? nil : [
            arm.filters.skipDeclined ? "skip-declined" : nil,
            arm.filters.skipAllDay ? "skip-all-day" : nil,
            arm.filters.skipDontClone ? "skip-dontclone" : nil,
        ].compactMap { $0 },
        syncState: status?.state.rawValue,
        lastSyncAt: InboxCLI.date(status?.lastSyncAt),
        lastError: status?.errorCategory,
        waiting: status?.waiting
    )
}

private func paddingText(_ padding: ArmPadding) -> String {
    let text = "\(padding.beforeMinutes) min before, \(padding.afterMinutes) min after"
    return padding.inPersonOnly ? text + ", in-person events only" : text
}
