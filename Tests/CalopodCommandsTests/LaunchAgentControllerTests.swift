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
