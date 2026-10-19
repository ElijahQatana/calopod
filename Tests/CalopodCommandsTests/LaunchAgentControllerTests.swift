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

// MARK: - Controls follow whichever service is active

#if os(macOS)
private let bundledLabel = AgentControlService.bundledLabel

/// A launchd double. `legacyDisabled` marks the source-installed agent disabled, and
/// `bundledLoaded` makes the app's bundled agent look loaded. Records every launchctl verb.
private func controlService(
    fixture: LaunchAgentFixture,
    legacyDisabled: Bool,
    bundledLoaded: Bool,
    bundled: Bool,
    verbs: Box<[String]>,
    legacyLoaded: Bool = false
) -> AgentControlService {
    let home = fixture.homeDirectory
    let state = fixture.stateURL
    return AgentControlService(
        bundledAgentExecutable: bundled
            ? URL(fileURLWithPath: "/Applications/Calopod.app/Contents/MacOS/calopod-agent")
            : nil,
        makeController: {
            try LaunchAgentController(homeDirectory: home, userID: 501) { arguments in
                verbs.value.append(arguments.first ?? "")
                switch arguments.first {
                case "print":
                    let target = arguments.dropFirst().first ?? ""
                    return LaunchctlResult(
                        exitCode: target.hasSuffix(bundledLabel) ? (bundledLoaded ? 0 : 1) : (legacyLoaded ? 0 : 1),
                        output: ""
                    )
                case "print-disabled":
                    return LaunchctlResult(
                        exitCode: 0,
                        output: legacyDisabled
                            ? #""pro.elijahquintana.calopod.agent" => disabled"#
                            : ""
                    )
                default:
                    return LaunchctlResult(exitCode: 0, output: "")
                }
            }
        },
        baseEnvironment: { ["CALOPOD_STATE_PATH": state.path] }
    )
}

@Test("The source install counts only while launchd has it loaded", arguments: [
    (true, false, false, true), (false, true, true, true), (false, false, false, true),
])
func sourceInstallIsReportedOnlyWhileLoaded(
    legacyDisabled: Bool, legacyLoaded: Bool, sourceLoaded: Bool, usesBundled: Bool
) throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let service = controlService(
        fixture: fixture, legacyDisabled: legacyDisabled, bundledLoaded: true, bundled: true,
        verbs: Box([]), legacyLoaded: legacyLoaded)
    let status = try service.status()
    #expect(status.sourceLoaded == sourceLoaded)
    #expect(status.usesBundledService == usesBundled)
}

@Test
func afterMovingToTheAppControlsActOnTheBundledAgent() async throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let verbs = Box<[String]>([])
    let service = controlService(
        fixture: fixture, legacyDisabled: true, bundledLoaded: true, bundled: true, verbs: verbs
    )

    let status = try service.status()
    #expect(status.installed)
    #expect(status.running)
    #expect(status.enabled)
    #expect(status.intervalSeconds == 600)
    #expect(status.lookbackDays == 7)
    #expect(status.horizonDays == 15)

    try service.setInterval(seconds: 300)
    #expect(try service.status().intervalSeconds == 300)
    #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path + ".schedule.json"))

    verbs.value.removeAll()
    try service.setPaused(true)
    #expect(try service.status().paused)
    #expect(!verbs.value.contains("bootout"))
    #expect(!verbs.value.contains("bootstrap"))

    #expect(throws: LaunchAgentControlError.runsFromApp) { try service.setEnabled(false) }
}

@Test
func theAppsServiceStaysLiveWhileTheSourceInstallIsAlsoOn() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let service = controlService(
        fixture: fixture, legacyDisabled: false, bundledLoaded: true, bundled: true, verbs: Box([]), legacyLoaded: true)

    try service.setInterval(seconds: 900)

    // The override file is written for the app's service and the source plist is left alone.
    #expect(try AgentServiceConfiguration.load(from: fixture.propertyListURL).intervalSeconds == 600)
    #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path + ".schedule.json"))
    let status = try service.status()
    #expect(status.usesBundledService)
    #expect(status.sourceLoaded)
    #expect(status.sourceEnabled)
}

private func enableBox(
    _ fixture: LaunchAgentFixture, appRegistered: Bool, appLoaded: Bool, sourceLoaded: Bool
) -> (service: AgentControlService, verbs: Box<[String]>, reregistered: Box<Int>) {
    let verbs = Box<[String]>([])
    let counter = Box(0)
    let started = Box(sourceLoaded)
    let home = fixture.homeDirectory
    let state = fixture.stateURL
    let service = AgentControlService(
        bundledAgentExecutable: appRegistered ? URL(fileURLWithPath: "/Applications/Calopod.app/Contents/MacOS/calopod-agent") : nil,
        makeController: {
            try LaunchAgentController(homeDirectory: home, userID: 501) { arguments in
                verbs.value.append(arguments.first ?? "")
                if arguments.first == "bootstrap" { started.value = true }
                if arguments.first == "print" {
                    let isApp = (arguments.dropFirst().first ?? "").hasSuffix(bundledLabel)
                    return LaunchctlResult(exitCode: (isApp ? appLoaded : started.value) ? 0 : 1, output: "")
                }
                if arguments.first == "print-disabled" {
                    return LaunchctlResult(exitCode: 0, output: started.value ? "" : #""pro.elijahquintana.calopod.agent" => disabled"#)
                }
                return LaunchctlResult(exitCode: 0, output: "")
            }
        },
        baseEnvironment: { ["CALOPOD_STATE_PATH": state.path] },
        reregisterBundled: { counter.value += 1 })
    return (service, verbs, counter)
}

@Test
func enableNeverStartsTheSourceInstallWhileTheAppsServiceIsRunning() async throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    // Only the app's service, running: nothing to do.
    let onlyApp = enableBox(fixture, appRegistered: true, appLoaded: true, sourceLoaded: false)
    try await onlyApp.service.enable()
    #expect(onlyApp.reregistered.value == 0)
    #expect(!onlyApp.verbs.value.contains("bootstrap") && !onlyApp.verbs.value.contains("enable"))

    // Both loaded: the app's service stays the live one, and the source install is not touched.
    let both = enableBox(fixture, appRegistered: true, appLoaded: true, sourceLoaded: true)
    try await both.service.enable()
    #expect(!both.verbs.value.contains("bootstrap") && !both.verbs.value.contains("enable"))
    #expect(try both.service.status().sourceLoaded)

    // The app's service registered but not running is registered again.
    let stopped = enableBox(fixture, appRegistered: true, appLoaded: false, sourceLoaded: false)
    try await stopped.service.enable()
    #expect(stopped.reregistered.value == 1)
    #expect(!stopped.verbs.value.contains("bootstrap"))
}

@Test
func enableRefusesToStartTheSourceInstallWhenTheAppsServiceIsLoadedButNotReported() async throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    // A command run outside the app cannot read the registration, but launchd shows the app's service.
    let outside = enableBox(fixture, appRegistered: false, appLoaded: true, sourceLoaded: false)
    await #expect(throws: LaunchAgentControlError.appServiceRunning) { try await outside.service.enable() }
    #expect(!outside.verbs.value.contains("bootstrap"))
}

@Test
func enableStartsTheSourceInstallOnlyWhenNoAppServiceExists() async throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let onlySource = enableBox(fixture, appRegistered: false, appLoaded: false, sourceLoaded: false)
    try await onlySource.service.enable()
    #expect(onlySource.verbs.value.contains("enable"))
    #expect(onlySource.reregistered.value == 0)
}

@Test
func disableLeavesTheAppsServiceAlone() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let app = enableBox(fixture, appRegistered: true, appLoaded: true, sourceLoaded: false)
    #expect(throws: LaunchAgentControlError.runsFromApp) { try app.service.setEnabled(false) }
    #expect(!app.verbs.value.contains("bootout") && !app.verbs.value.contains("disable"))
}

@Test
func doctorNamesTheSourceInstallWhenBothAreLoaded() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let both = enableBox(fixture, appRegistered: true, appLoaded: true, sourceLoaded: true)
    let report = try both.service.doctor()
    #expect(report.items.contains { $0.id == "source-install" && $0.reason == "also-running" })
    let only = enableBox(fixture, appRegistered: true, appLoaded: true, sourceLoaded: false)
    #expect(try !only.service.doctor().items.contains { $0.id == "source-install" })
}

@Test
func neitherServiceRunningIsReportedAsDisabledOrStoppedWithAFix() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let neither = enableBox(fixture, appRegistered: false, appLoaded: false, sourceLoaded: false)
    let payload = try neither.service.statusPayload()
    #expect(payload.status == "disabled")
    #expect(payload.message.contains("calopod agent enable") == true)
}

@Test
func withoutABundledAgentTheStatusReflectsTheSourceInstall() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let service = controlService(
        fixture: fixture, legacyDisabled: true, bundledLoaded: true, bundled: false, verbs: Box([])
    )

    let status = try service.status()
    #expect(status.state == "disabled")
    #expect(!status.enabled)
}
#endif

@Test
func turningOffTheSourceInstallLeavesTheAppsServiceSyncing() throws {
    let fixture = try LaunchAgentFixture()
    defer { fixture.remove() }
    let verbs = Box<[String]>([])
    let sourceLoaded = Box(true)
    let sourceDisabled = Box(false)
    let home = fixture.homeDirectory
    let state = fixture.stateURL
    let service = AgentControlService(
        bundledAgentExecutable: URL(fileURLWithPath: "/Applications/Calopod.app/Contents/MacOS/calopod-agent"),
        makeController: {
            try LaunchAgentController(homeDirectory: home, userID: 501) { arguments in
                verbs.value.append(arguments.joined(separator: " "))
                switch arguments.first {
                case "print":
                    let isApp = (arguments.dropFirst().first ?? "").hasSuffix(bundledLabel)
                    return LaunchctlResult(exitCode: isApp || sourceLoaded.value ? 0 : 1, output: "")
                case "print-disabled":
                    return LaunchctlResult(
                        exitCode: 0, output: sourceDisabled.value ? #""pro.elijahquintana.calopod.agent" => disabled"# : "")
                case "bootout": sourceLoaded.value = false
                case "disable": sourceDisabled.value = true
                default: break
                }
                return LaunchctlResult(exitCode: 0, output: "")
            }
        },
        baseEnvironment: { ["CALOPOD_STATE_PATH": state.path] })

    let before = try service.status()
    #expect(before.sourceLoaded && before.sourceEnabled)

    try service.disableSourceInstall()

    // Only the old job is touched, and the app's service still reads as on and not paused.
    #expect(verbs.value.contains { $0.hasPrefix("bootout") && $0.hasSuffix(".agent") })
    #expect(verbs.value.allSatisfy { !$0.hasSuffix(bundledLabel) || $0.hasPrefix("print") })
    let after = try service.status()
    #expect(after.usesBundledService && after.enabled && after.running && !after.paused)
    #expect(!after.sourceLoaded && !after.sourceEnabled)
    #expect(try service.doctor().items.contains { $0.id == "source-install" } == false)
}

@Test
func plainDisableExplainsWhatIsLiveAndTheCommandHasASourceFlag() throws {
    #expect(try AgentDisableCommand.parse(["--source"]).source)
    #expect(try !AgentDisableCommand.parse([]).source)
    let cli = commandFailure(LaunchAgentControlError.runsFromApp).message
    #expect(cli.contains("agent pause") && cli.contains("agent disable --source"))
    let app = appFailureMessage(LaunchAgentControlError.runsFromApp)
    #expect(app.contains("Pause") && app.contains("Turn off source install"))
}
