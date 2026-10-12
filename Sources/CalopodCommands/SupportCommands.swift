import ArgumentParser
import CalopodDomain
import CalopodRuntime
import CalopodStore
import Foundation

public struct SupportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "support",
        abstract: "Export diagnostics and protect local state.",
        subcommands: [
            SupportExportCommand.self,
            SupportBackupCommand.self,
            SupportVerifyCommand.self,
            SupportRestoreCommand.self,
        ]
    )

    public init() {}
}

public struct SupportExportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export sanitized health and configuration."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            let result = try supportExport(controller: controller)
            try OutputRenderer.write(
                command: "support.export",
                payload: result.payload,
                warnings: result.warnings,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct SupportBackupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Create and verify a private local-state backup."
    )

    @Option(name: .customLong("output"), help: "Absolute path for the new backup file.")
    public var outputPath: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let environment = try supportEnvironment()
            let lock = try ProcessLock.acquire(at: environment.stateLocation.lockURL)
            defer { withExtendedLifetime(lock) {} }
            let summary = try LocalStateBackup.create(
                from: environment.stateLocation.databaseURL.path,
                at: outputPath
            )
            try writeBackupResult(
                command: "support.backup",
                message: "The private local-state backup was created and verified.",
                summary: summary,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

public struct SupportVerifyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a private local-state backup."
    )

    @Option(name: .customLong("backup"), help: "Absolute path to the backup file.")
    public var backupPath: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let summary = try LocalStateBackup.verify(at: backupPath)
            try writeBackupResult(
                command: "support.verify",
                message: "The private local-state backup is valid.",
                summary: summary,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

public struct SupportRestoreCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore local state while automatic sync is disabled."
    )

    @Option(name: .customLong("backup"), help: "Absolute path to the backup file.")
    public var backupPath: String

    @Flag(name: .long, help: "Confirm replacement of the current local state.")
    public var confirm = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func validate() throws {
        guard confirm else {
            throw ValidationError("Pass --confirm after verifying the backup.")
        }
    }

    public func run() throws {
        #if os(macOS)
        do {
            let controller = try LaunchAgentController()
            let snapshot = try controller.snapshot()
            try requireServiceStoppedForRestore(snapshot)
            let environment = try supportEnvironment(snapshot: snapshot)
            let summary = try environment.restoreState(from: backupPath)
            try writeBackupResult(
                command: "support.restore",
                message: "Local state was restored from the verified backup.",
                summary: summary,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

enum SupportCommandError: Error {
    case serviceMustBeStopped
}

struct SupportConfigurationCounts: Equatable {
    let connectionCount: Int
    let enabledConnectionCount: Int
    let selectedCalendarCount: Int
    let armCount: Int
    let enabledArmCount: Int
    let mainConfigured: Bool
    let busyArmCount: Int
}

func supportConfigurationCounts(
    repository: LocalStateRepository
) throws -> SupportConfigurationCounts {
    let connections = try repository.connections()
    let calendars = try connections.flatMap { connection in
        try repository.calendarBindings(connectionID: connection.id)
    }
    let arms = try repository.arms()
    return SupportConfigurationCounts(
        connectionCount: connections.count,
        enabledConnectionCount: connections.filter(\.isEnabled).count,
        selectedCalendarCount: calendars.filter(\.isSelected).count,
        armCount: arms.count,
        enabledArmCount: arms.filter(\.isEnabled).count,
        mainConfigured: arms.contains(where: \.isMain),
        busyArmCount: arms.filter { !$0.isMain && $0.ruleMode == .busy }.count
    )
}

#if os(macOS)
private func supportExport(
    controller: LaunchAgentController
) throws -> (payload: CommandPayload, warnings: [String]) {
    let snapshot = try controller.snapshot()
    let report = try doctorReport(controller: controller)
    var paused: Bool?
    var counts: SupportConfigurationCounts?
    if let configuration = snapshot.configuration,
       FileManager.default.fileExists(atPath: configuration.stateURL.path),
       let repository = try? installedAgentEnvironment(controller: controller).repository() {
        paused = try? repository.agentControl().isPaused
        counts = try? supportConfigurationCounts(repository: repository)
    }
    return (
        CommandPayload(
            status: report.status,
            message: "Sanitized support information is ready.",
            count: report.items.count,
            items: report.items,
            installed: snapshot.installed,
            enabled: snapshot.installed && !snapshot.disabled,
            paused: paused,
            runState: snapshot.loaded ? "running" : "stopped",
            stateReady: snapshot.configuration.map {
                FileManager.default.fileExists(atPath: $0.stateURL.path)
            } ?? false,
            intervalSeconds: snapshot.configuration?.intervalSeconds,
            jitterSeconds: snapshot.configuration?.jitterSeconds,
            lookbackDays: snapshot.configuration?.lookbackDays,
            horizonDays: snapshot.configuration?.horizonDays,
            warningCount: report.warnings.count,
            connectionCount: counts?.connectionCount,
            enabledConnectionCount: counts?.enabledConnectionCount,
            selectedCalendarCount: counts?.selectedCalendarCount,
            armCount: counts?.armCount,
            enabledArmCount: counts?.enabledArmCount,
            mainConfigured: counts?.mainConfigured,
            busyArmCount: counts?.busyArmCount
        ),
        report.warnings
    )
}

func requireServiceStoppedForRestore(_ snapshot: LaunchAgentSnapshot) throws {
    if snapshot.installed, !snapshot.disabled || snapshot.loaded {
        throw SupportCommandError.serviceMustBeStopped
    }
}

private func supportEnvironment(
    snapshot suppliedSnapshot: LaunchAgentSnapshot? = nil
) throws -> CalopodRuntimeEnvironment {
    let controller = try LaunchAgentController()
    let snapshot = try suppliedSnapshot ?? controller.snapshot()
    if snapshot.configuration != nil {
        return try installedAgentEnvironment(controller: controller)
    }
    return try CommandEnvironment.runtimeEnvironment()
}
#endif

private func writeBackupResult(
    command: String,
    message: String,
    summary: LocalStateBackupSummary,
    format: OutputFormat
) throws {
    try OutputRenderer.write(
        command: command,
        payload: CommandPayload(
            status: "ok",
            message: message,
            backupValid: true,
            migrationCount: summary.migrationCount
        ),
        format: format
    )
}
