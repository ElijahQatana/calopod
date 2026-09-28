import ArgumentParser
import CalopodEventKit
import CalopodRuntime
import CalopodStore
import Foundation

public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect automatic-sync installation and health."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        #if os(macOS)
        do {
            let report = try doctorReport()
            try OutputRenderer.write(
                command: "doctor",
                payload: CommandPayload(
                    status: report.status,
                    message: report.message,
                    count: report.items.count,
                    items: report.items,
                    warningCount: report.warnings.count
                ),
                warnings: report.warnings,
                format: output.format
            )
            if report.status == "failed" {
                throw ExitCode(CalopodExitCode.unavailable.rawValue)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            try failCommand(error)
        }
        #else
        try failCommand(CalopodRuntimeError.unsupportedPlatform)
        #endif
    }
}

struct DoctorReport: Equatable {
    let status: String
    let message: String
    let items: [CommandItem]
    let warnings: [String]
}

#if os(macOS)
private func doctorReport() throws -> DoctorReport {
    let controller = try LaunchAgentController()
    let snapshot: LaunchAgentSnapshot
    do {
        snapshot = try controller.snapshot()
    } catch is AgentServiceConfigurationError {
        return DoctorReport(
            status: "failed",
            message: "The automatic-sync installation needs attention.",
            items: [doctorItem("installation", "failed", "configuration")],
            warnings: ["Reinstall the Calopod user service."]
        )
    }
    guard let configuration = snapshot.configuration else {
        return DoctorReport(
            status: "failed",
            message: "The automatic-sync service is not installed.",
            items: [doctorItem("installation", "failed", "not-installed")],
            warnings: ["Install the Calopod user service."]
        )
    }

    var items: [CommandItem] = []
    var warnings: [String] = []
    let hostExecutable = configuration.eventKitHostURL
        .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
    if FileManager.default.isExecutableFile(atPath: configuration.programURL.path),
       FileManager.default.isExecutableFile(atPath: hostExecutable.path) {
        items.append(doctorItem("installation", "ok"))
    } else {
        items.append(doctorItem("installation", "failed", "installation"))
        warnings.append("Rebuild and reinstall the user service.")
    }
    let serviceCheck = serviceHealthCheck(snapshot)
    items.append(serviceCheck.item)
    if let warning = serviceCheck.warning {
        warnings.append(warning)
    }

    guard FileManager.default.fileExists(atPath: configuration.stateURL.path) else {
        items.append(doctorItem("state", "pending"))
        warnings.append("Run automatic sync once to initialize local state.")
        return doctorReport(items: items, warnings: warnings)
    }

    let permissions = try FileManager.default.attributesOfItem(
        atPath: configuration.stateURL.path
    )[.posixPermissions] as? NSNumber
    if let permissions, permissions.intValue & 0o077 == 0 {
        items.append(doctorItem("state", "ok"))
    } else {
        items.append(doctorItem("state", "failed", "local-state"))
        warnings.append("Repair local state permissions before running automatic sync.")
    }

    let repository: LocalStateRepository
    do {
        repository = try installedAgentEnvironment(controller: controller).repository()
    } catch {
        items.append(doctorItem("database", "failed", "local-state"))
        warnings.append("Repair or restore local state before running automatic sync.")
        return doctorReport(items: items, warnings: warnings)
    }
    items.append(doctorItem("database", "ok"))
    if try repository.agentControl().isPaused {
        items.append(doctorItem("schedule", "pending", "paused"))
        warnings.append("Resume automatic sync when scheduled runs should continue.")
    } else {
        items.append(doctorItem("schedule", "ok"))
    }

    let connections = try repository.connections().filter(\.isEnabled)
    if connections.isEmpty {
        items.append(doctorItem("connections", "pending"))
        warnings.append("Configure and enable at least one calendar Connection.")
    } else {
        items.append(doctorItem("connections", "ok"))
        let providerConnections = try automaticSyncSourceConnections(repository: repository)
        let providerCheck = try providerHealthCheck(
            connections: providerConnections,
            repository: repository
        )
        items.append(providerCheck)
        if providerConnections.isEmpty {
            warnings.append("Enable an Arm with selected source calendars to check provider health.")
        } else if providerCheck.kind == "pending" {
            warnings.append("Run automatic sync once to check provider health.")
        } else if providerCheck.kind == "failed" {
            warnings.append(actionForFailure(providerCheck.reason))
        }
    }

    if connections.contains(where: { $0.provider == "eventkit" }) {
        do {
            let response = try EventKitHostRunner(environment: configuration.environment)
                .perform(EventKitHostRequest(operation: .permissionStatus))
            if response.status == .fullAccess, response.errorCode == nil {
                items.append(doctorItem("calendar-permission", "ok"))
            } else {
                items.append(doctorItem("calendar-permission", "failed", "permission"))
                warnings.append("Grant Calendar access, then refresh the Mac Connection.")
            }
        } catch {
            items.append(doctorItem("calendar-permission", "failed", "eventkit-host"))
            warnings.append("Verify the EventKit host signature and reinstall the user service.")
        }
    }

    if let latest = try repository.latestSyncRun(trigger: "automatic") {
        if latest.status == "failed" || latest.status == "interrupted" {
            let category = genericFailureCategory(latest.errorCode)
            items.append(doctorItem("automatic-run", "failed", category))
            warnings.append(actionForFailure(category))
        } else {
            items.append(doctorItem("automatic-run", "ok"))
        }
    } else {
        items.append(doctorItem("automatic-run", "pending"))
        warnings.append("Run automatic sync once to establish service health.")
    }

    return doctorReport(items: items, warnings: warnings)
}
#endif

func providerHealthCheck(
    connections: [StoredConnection],
    repository: LocalStateRepository
) throws -> CommandItem {
    guard !connections.isEmpty else {
        return doctorItem("provider-health", "pending", "inactive")
    }
    var sawUnchecked = false
    for connection in connections {
        guard let health = try repository.connectionHealth(connectionID: connection.id) else {
            sawUnchecked = true
            continue
        }
        if health.status != "healthy" {
            return doctorItem(
                "provider-health",
                "failed",
                genericFailureCategory(health.errorCode)
            )
        }
    }
    return doctorItem("provider-health", sawUnchecked ? "pending" : "ok")
}

func automaticSyncSourceConnections(
    repository: LocalStateRepository
) throws -> [StoredConnection] {
    var connectionsByID: [String: StoredConnection] = [:]
    for arm in try repository.arms() where arm.isEnabled {
        guard let target = try repository.calendarBinding(id: arm.targetBindingID),
              let targetConnection = try repository.connection(id: target.connectionID),
              targetConnection.isEnabled else {
            continue
        }

        var sourceConnections: [StoredConnection] = []
        for sourceID in arm.sourceBindingIDs {
            guard let source = try repository.calendarBinding(id: sourceID),
                  source.isSelected,
                  let connection = try repository.connection(id: source.connectionID),
                  connection.isEnabled else {
                sourceConnections.removeAll()
                break
            }
            sourceConnections.append(connection)
        }
        for connection in sourceConnections {
            connectionsByID[connection.id] = connection
        }
    }
    return connectionsByID.values.sorted { $0.id < $1.id }
}

func serviceHealthCheck(
    _ snapshot: LaunchAgentSnapshot
) -> (item: CommandItem, warning: String?) {
    if snapshot.disabled {
        return (
            doctorItem("service", "pending", "disabled"),
            "Enable automatic sync when scheduled runs should continue."
        )
    }
    if !snapshot.loaded {
        return (
            doctorItem("service", "failed", "stopped"),
            "Enable automatic sync to start the installed service."
        )
    }
    return (doctorItem("service", "ok"), nil)
}

func genericFailureCategory(_ value: String?) -> String {
    let allowed = Set([
        "account-policy",
        "ambiguous-repair",
        "authorization",
        "busy",
        "configuration",
        "consent",
        "convergence",
        "credential-access",
        "cursor",
        "eventkit-host",
        "eventkit-host-response",
        "interrupted",
        "local-state",
        "permission",
        "provider-http",
        "provider-response",
        "source-refresh",
        "target-refresh",
        "temporary",
        "unsupported-platform",
        "writer-policy",
    ])
    guard let value, allowed.contains(value) else { return "provider" }
    return value
}

private func doctorItem(
    _ id: String,
    _ kind: String,
    _ reason: String? = nil
) -> CommandItem {
    CommandItem(id: id, kind: kind, reason: reason)
}

private func actionForFailure(_ category: String?) -> String {
    switch category {
    case "authorization", "account-policy", "consent", "credential-access":
        "Reconnect the affected calendar account."
    case "permission":
        "Grant Calendar access, then refresh the Mac Connection."
    case "eventkit-host", "eventkit-host-response":
        "Verify the EventKit host signature and reinstall the user service."
    case "local-state":
        "Repair or restore local state before running automatic sync."
    case "configuration", "writer-policy":
        "Review the enabled Connections and Arms before retrying."
    default:
        "Retry after provider connectivity recovers."
    }
}

private func doctorReport(
    items: [CommandItem],
    warnings: [String]
) -> DoctorReport {
    let uniqueWarnings = Array(Set(warnings)).sorted()
    let status: String
    let message: String
    if items.contains(where: { $0.kind == "failed" }) {
        status = "failed"
        message = "Automatic sync needs attention."
    } else if items.contains(where: { $0.kind == "pending" }) {
        status = "attention"
        message = "Automatic sync has checks that are not complete yet."
    } else {
        status = "ok"
        message = "Automatic sync checks passed."
    }
    return DoctorReport(
        status: status,
        message: message,
        items: items,
        warnings: uniqueWarnings
    )
}
