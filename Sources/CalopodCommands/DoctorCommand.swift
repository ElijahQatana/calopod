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
            let report = try doctorReport(controller: LaunchAgentController(), permissions: livePermissionReadings, calendarHelper: liveCalendarHelper)
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
                format: output.format,
                showIDs: output.ids
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
func doctorReport(
    controller: LaunchAgentController,
    permissions: () -> [PermissionReading] = { [] },
    calendarHelper: () -> String? = { nil }
) throws -> DoctorReport {
    withPermissions(try serviceReport(controller: controller), permissions(), calendarHelper: calendarHelper())
}

private func serviceReport(controller: LaunchAgentController) throws -> DoctorReport {
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
    return try doctorReport(
        snapshot: snapshot,
        environment: { try installedAgentEnvironment(controller: controller) }
    )
}

func doctorReport(
    snapshot: LaunchAgentSnapshot,
    environment makeEnvironment: () throws -> CalopodRuntimeEnvironment
) throws -> DoctorReport {
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
        repository = try makeEnvironment().repository()
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
        var helper: String?
        do {
            let runner = try EventKitHostRunner(environment: configuration.environment)
            helper = runner.hostURL.path
            let response = try runner
                .perform(EventKitHostRequest(operation: .permissionStatus))
            if response.status == .fullAccess, response.errorCode == nil {
                items.append(doctorItem("calendar-permission", "ok", label: helper.map(shortPath)))
            } else {
                items.append(doctorItem("calendar-permission", "failed", "permission", label: helper.map(shortPath)))
                warnings.append("Grant Calendar access, then refresh the Mac Connection.")
            }
        } catch {
            var category = "eventkit-host"
            if case CommandEnvironmentError.eventKitHostTimedOut = error {
                category = "eventkit-host-timeout"
            }
            items.append(doctorItem("calendar-permission", "failed", category, label: helper.map(shortPath)))
            warnings.append(actionForFailure(category))
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

/// The three macOS permissions, read the way the app reads them. Nothing here can raise a prompt.
func livePermissionReadings() -> [PermissionReading] {
    let calendar: PermissionReading
    do {
        calendar = Permissions.calendar(status: try CalendarAccessService().status())
    } catch {
        calendar = Permissions.calendar(status: nil, hostFailure: Permissions.hostFailureReason(error))
    }
    return [
        calendar,
        Permissions.backgroundService(.read()),
        Permissions.keychain(KeychainAccessCheck.live.run(interactive: false)),
    ]
}
#endif

/// The Calendar helper this command would ask, so a mismatch with the app is visible.
func liveCalendarHelper() -> String? {
    try? CalendarAccessService().hostURL().path
}

private func shortPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

/// Adds the permission checks to a report. Anything not allowed is flagged for attention, and
/// the warning carries the same words as the app's Permissions list.
func withPermissions(_ report: DoctorReport, _ readings: [PermissionReading], calendarHelper: String? = nil) -> DoctorReport {
    guard !readings.isEmpty else { return report }
    let ids = [PermissionReading.ID.calendar: "permission-calendar", .loginItems: "permission-login-items", .keychain: "permission-keychain"]
    var items = report.items
    var warnings = report.warnings
    for reading in readings {
        let kind: String
        switch reading.level {
        case .allowed: kind = "ok"
        case .notAsked, .blocked: kind = "attention"
        case .unknown: kind = reading.reason == "unreachable" ? "attention" : "skipped"
        }
        let helper = reading.id == .calendar ? calendarHelper.map(shortPath) : nil
        items.append(doctorItem(ids[reading.id] ?? reading.id.rawValue, kind, reading.reason, label: helper))
        if kind == "attention" { warnings.append("\(reading.title): \(reading.detail)") }
    }
    let merged = doctorReport(items: items, warnings: warnings)
    return report.status == "failed" ? DoctorReport(status: report.status, message: report.message, items: items, warnings: merged.warnings) : merged
}

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
            "Automatic sync is off. Run calopod agent enable, or choose Enable automatic sync in the Calopod app."
        )
    }
    if !snapshot.loaded {
        return (
            doctorItem("service", "failed", "stopped"),
            "Automatic sync is enabled but not running. Run calopod agent enable to start it again, or choose Enable automatic sync in the Calopod app."
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
        "client-id",
        "configuration",
        "consent",
        "convergence",
        "credential-access",
        "cursor",
        "eventkit-host",
        "eventkit-host-response",
        "eventkit-host-timeout",
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
    _ reason: String? = nil,
    label: String? = nil
) -> CommandItem {
    CommandItem(id: id, kind: kind, label: label, reason: reason)
}

private func actionForFailure(_ category: String?) -> String {
    switch category {
    case "authorization", "account-policy", "consent", "credential-access":
        "Reconnect the affected calendar account."
    case "permission":
        "Grant Calendar access, then refresh the Mac Connection."
    case "eventkit-host-timeout":
        "The Calendar host did not respond in time. Retry, or restart the user service."
    case "eventkit-host", "eventkit-host-response":
        "Verify the EventKit host signature and reinstall the user service."
    case "local-state":
        "Repair or restore local state before running automatic sync."
    case "client-id":
        "Reinstall the user service with the provider client ID set in the environment."
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
    } else if items.contains(where: { $0.kind == "pending" || $0.kind == "attention" }) {
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
