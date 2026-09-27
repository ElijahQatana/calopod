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
            output: #""com.calopod.agent" => true"#
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
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        return LaunchctlResult(
            exitCode: arguments.first == "print" ? 1 : 0,
            output: ""
        )
    }

    try controller.enable()

    #expect(calls.map(\.first) == ["enable", "print", "bootstrap"])
    #expect(calls.last == [
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
    let controller = try LaunchAgentController(
        homeDirectory: fixture.homeDirectory,
        userID: 501
    ) { arguments in
        calls.append(arguments)
        return LaunchctlResult(exitCode: 0, output: "")
    }

    try controller.disable()

    #expect(calls.map(\.first) == ["print", "bootout", "disable"])
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
            output: #""com.calopod.agent" => true"#
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
            .appendingPathComponent("com.calopod.agent.plist")
        stateURL = root.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(
            at: propertyListURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let propertyList: [String: Any] = [
            "Label": "com.calopod.agent",
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
