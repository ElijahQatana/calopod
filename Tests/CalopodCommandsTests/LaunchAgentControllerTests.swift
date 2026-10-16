@testable import CalopodCommands
import Foundation
import Testing

#if os(macOS)
@Test
func launchAgentControllerReportsInstalledLaunchdState() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        switch arguments.first {
        case "print": LaunchctlResult(exitCode: 0, output: "")
        case "print-disabled": LaunchctlResult(
            exitCode: 0,
            output: #""pro.elijahquintana.calopod.agent" => disabled"#
        )
        default: LaunchctlResult(exitCode: 1, output: "")
        }
    }

    let snapshot = try controller.snapshot()

    #expect(snapshot.installed)
    #expect(snapshot.loaded)
    #expect(snapshot.disabled)
    #expect(snapshot.configuration?.intervalSeconds == 600)
}

@Test
func enablingBootstrapsAnInstalledAgent() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    var calls: [[String]] = []
    var isLoaded = false
    var isDisabled = true
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        switch arguments.first {
        case "enable":
            isDisabled = false
            return LaunchctlResult(exitCode: 0, output: "")
        case "bootstrap":
            isLoaded = true
            return LaunchctlResult(exitCode: 0, output: "")
        case "print":
            return LaunchctlResult(exitCode: isLoaded ? 0 : 1, output: "")
        case "print-disabled":
            return LaunchctlResult(
                exitCode: 0,
                output: isDisabled ? #""pro.elijahquintana.calopod.agent" => disabled"# : ""
            )
        default:
            return LaunchctlResult(exitCode: 1, output: "")
        }
    }

    try controller.enable()

    #expect(calls.map(\.first) == [
        "enable", "print", "bootstrap", "print", "print-disabled",
    ])
    #expect(calls[2] == [
        "bootstrap",
        "gui/501",
        fixture.propertyListURL.path,
    ])
}

@Test
func disablingBootsOutBeforePersistingTheDisabledState() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    var calls: [[String]] = []
    var isLoaded = true
    var isDisabled = false
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        switch arguments.first {
        case "bootout":
            isLoaded = false
            return LaunchctlResult(exitCode: 0, output: "")
        case "disable":
            isDisabled = true
            return LaunchctlResult(exitCode: 0, output: "")
        case "print":
            return LaunchctlResult(exitCode: isLoaded ? 0 : 1, output: "")
        case "print-disabled":
            return LaunchctlResult(
                exitCode: 0,
                output: isDisabled ? #""pro.elijahquintana.calopod.agent" => disabled"# : ""
            )
        default:
            return LaunchctlResult(exitCode: 1, output: "")
        }
    }

    try controller.disable()

    #expect(calls.map(\.first) == [
        "print", "bootout", "disable", "print", "print-disabled",
    ])
}

@Test
func restartLeavesADisabledAgentUnloaded() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    var calls: [[String]] = []
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        switch arguments.first {
        case "print": return LaunchctlResult(exitCode: 0, output: "")
        case "print-disabled": return LaunchctlResult(
            exitCode: 0,
            output: #""pro.elijahquintana.calopod.agent" => true"#
        )
        default: return LaunchctlResult(exitCode: 0, output: "")
        }
    }

    try controller.restartIfEnabled()

    #expect(calls.map(\.first) == ["print", "bootout", "print-disabled"])
}

/// Simulates launchd: `bootout` unloads, `bootstrap` fails `failures` times before loading.
private func restartController(
    fixture: LaunchAgentFixture,
    failures: Int,
    loadedDespiteFailure: Bool = false,
    calls: Box<[String]>,
    delays: Box<[TimeInterval]>
) throws -> LaunchAgentController {
    var loaded = true
    var remainingFailures = failures
    return try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501,
        launchctl: { arguments in
            calls.value.append(arguments.first ?? "")
            switch arguments.first {
            case "print":
                return LaunchctlResult(exitCode: loaded ? 0 : 1, output: "")
            case "print-disabled":
                return LaunchctlResult(exitCode: 0, output: "")
            case "bootout":
                loaded = false
                return LaunchctlResult(exitCode: 0, output: "")
            case "bootstrap":
                if remainingFailures > 0 {
                    remainingFailures -= 1
                    if loadedDespiteFailure { loaded = true }
                    return LaunchctlResult(exitCode: 5, output: "")
                }
                loaded = true
                return LaunchctlResult(exitCode: 0, output: "")
            default:
                return LaunchctlResult(exitCode: 1, output: "")
            }
        },
        pause: { delays.value.append($0) }
    )
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Test
func restartRetriesBootstrapWhileLaunchdFinishesBootout() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let calls = Box<[String]>([])
    let delays = Box<[TimeInterval]>([])
    let controller = try restartController(
        fixture: fixture, failures: 2, calls: calls, delays: delays
    )

    try controller.restartIfEnabled()

    #expect(calls.value.filter { $0 == "bootstrap" }.count == 3)
    #expect(delays.value == [0.25, 0.5])
}

@Test
func restartReportsFailureWhenBootstrapNeverSucceeds() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let calls = Box<[String]>([])
    let delays = Box<[TimeInterval]>([])
    let controller = try restartController(
        fixture: fixture, failures: 100, calls: calls, delays: delays
    )

    #expect(throws: LaunchAgentControlError.operationFailed("bootstrap")) {
        try controller.restartIfEnabled()
    }
    #expect(calls.value.filter { $0 == "bootstrap" }.count == 5)
    #expect(delays.value == LaunchAgentController.bootstrapRetryDelays)
}

@Test
func restartAcceptsAFailedBootstrapThatLeftTheServiceLoaded() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let calls = Box<[String]>([])
    let delays = Box<[TimeInterval]>([])
    let controller = try restartController(
        fixture: fixture, failures: 1, loadedDespiteFailure: true, calls: calls, delays: delays
    )

    try controller.restartIfEnabled()

    #expect(calls.value.filter { $0 == "bootstrap" }.count == 1)
    #expect(delays.value.isEmpty)
}

@Test
func agentStatusDoesNotCreateMissingState() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        LaunchctlResult(
            exitCode: arguments.first == "print-disabled" || arguments.first == "print" ? 0 : 1,
            output: ""
        )
    }

    let payload = try agentStatusPayload(controller: controller)

    #expect(payload.status == "ok")
    #expect(payload.installed == true)
    #expect(payload.enabled == true)
    #expect(payload.runState == "running")
    #expect(payload.stateReady == false)
    #expect(!FileManager.default.fileExists(atPath: fixture.stateURL.path))
}

@Test
func invalidInstalledScheduleIsReportedAsConfiguration() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    var plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: fixture.propertyListURL), options: [], format: nil
    ) as! [String: Any]
    var variables = plist["EnvironmentVariables"] as! [String: String]
    variables["CALOPOD_AGENT_INTERVAL_SECONDS"] = "0"
    plist["EnvironmentVariables"] = variables
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: fixture.propertyListURL)
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { _ in LaunchctlResult(exitCode: 0, output: "") }

    let status = try agentStatusPayload(controller: controller)
    let doctor = try doctorReport(controller: controller)

    #expect(status.status == "failed")
    #expect(status.failureCategory == "configuration")
    #expect(doctor.status == "failed")
    #expect(doctor.items.first?.reason == "configuration")
}

@Test
func scheduleUpdatePreservesPathsAndRestartsALoadedAgent() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    var calls: [[String]] = []
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        return LaunchctlResult(exitCode: 0, output: "")
    }

    try controller.updateSchedule(
        intervalSeconds: 900,
        jitterSeconds: 45,
        lookbackDays: 2,
        horizonDays: 21
    )

    let updated = try AgentServiceConfiguration.load(from: fixture.propertyListURL)
    #expect(updated.intervalSeconds == 900)
    #expect(updated.jitterSeconds == 45)
    #expect(updated.lookbackDays == 2)
    #expect(updated.horizonDays == 21)
    #expect(updated.stateURL == fixture.stateURL.standardizedFileURL)
    #expect(updated.programURL.path == "/example/bin/calopod-agent")
    #expect(calls.map(\.first) == ["print", "print-disabled", "bootout", "bootstrap"])
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: fixture.propertyListURL.path)[.posixPermissions]
            as? NSNumber
    )
    #expect(mode.intValue == 0o600)
}

private struct LaunchAgentFixture {
    let root: URL
    let homeDirectory: URL
    let propertyListURL: URL
    let stateURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-launchctl-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        propertyListURL = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("pro.elijahquintana.calopod.agent.plist")
        stateURL = root.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(
            at: propertyListURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let propertyList: [String: Any] = [
            "Label": "pro.elijahquintana.calopod.agent",
            "ProgramArguments": ["/example/bin/calopod-agent"],
            "EnvironmentVariables": [
                "CALOPOD_STATE_PATH": stateURL.path,
                "CALOPOD_EVENTKIT_HOST_APP": "/example/EventKit Host.app",
                "CALOPOD_AGENT_INTERVAL_SECONDS": "600",
                "CALOPOD_AGENT_JITTER_SECONDS": "30",
                "CALOPOD_AGENT_LOOKBACK_DAYS": "1",
                "CALOPOD_AGENT_HORIZON_DAYS": "30",
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: propertyListURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
