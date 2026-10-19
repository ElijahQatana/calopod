#if os(macOS)
import CalopodRuntime
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

private let appLabel = AgentControlService.bundledLabel
private let appProgram = "/Applications/Calopod.app/Contents/MacOS/calopod-agent"

private final class Calls: @unchecked Sendable {
    var verbs: [String] = []
}

/// A temp folder with an app, a link to the command inside it, a source plist and a state file.
private struct World {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-locator-\(UUID().uuidString)", isDirectory: true)
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var app: URL { root.appendingPathComponent("Applications/Calopod.app", isDirectory: true) }
    var inside: URL { app.appendingPathComponent("Contents/MacOS/calopod") }
    var link: URL { root.appendingPathComponent("bin/calopod") }
    var state: URL { root.appendingPathComponent("state.sqlite") }

    init(sourceInstalled: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: inside.path, contents: Data())
        try fm.createSymbolicLink(at: link, withDestinationURL: inside)
        let host = inside.deletingLastPathComponent()
            .appendingPathComponent("eventkit-host/Calopod EventKit Host.app", isDirectory: true)
        let helper = host.appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        guard sourceInstalled else { return }
        let plist = home.appendingPathComponent("Library/LaunchAgents/pro.elijahquintana.calopod.agent.plist")
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values: [String: Any] = [
            "Label": "pro.elijahquintana.calopod.agent",
            "ProgramArguments": ["/example/bin/calopod-agent"],
            "EnvironmentVariables": [
                "CALOPOD_STATE_PATH": root.appendingPathComponent("source.sqlite").path,
                "CALOPOD_EVENTKIT_HOST_APP": "/example/source/Calopod EventKit Host.app",
                "CALOPOD_AGENT_INTERVAL_SECONDS": "300", "CALOPOD_AGENT_JITTER_SECONDS": "30",
                "CALOPOD_AGENT_LOOKBACK_DAYS": "1", "CALOPOD_AGENT_HORIZON_DAYS": "30",
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Fake launchd. The app label is loaded as `appLoaded`; the source label as `sourceLoaded`.
    func service(
        from executable: URL, mainBundle: URL? = nil, registration: BackgroundServiceState = .unavailable,
        appLoaded: Bool = false, sourceLoaded: Bool = false, calls: Calls = Calls()
    ) -> AgentControlService {
        let home = home
        let appAgent = app.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/calopod-agent").path
        let controller: @Sendable () throws -> LaunchAgentController = {
            try LaunchAgentController(homeDirectory: home, userID: 501) { arguments in
                calls.verbs.append(arguments.joined(separator: " "))
                switch arguments.first {
                case "print":
                    let isApp = (arguments.dropFirst().first ?? "").hasSuffix(appLabel)
                    let loaded = isApp ? appLoaded : sourceLoaded
                    return LaunchctlResult(exitCode: loaded ? 0 : 113, output: isApp ? "\tprogram = \(appAgent)\n" : "")
                default:
                    return LaunchctlResult(exitCode: 0, output: "")
                }
            }
        }
        let state = state
        return AgentControlService.current(
            executableURL: executable,
            mainBundleURL: mainBundle ?? root.appendingPathComponent("elsewhere", isDirectory: true),
            registration: { registration },
            makeController: controller,
            baseEnvironment: { ["CALOPOD_STATE_PATH": state.path] }
        )
    }

    /// An automatic run that failed `ago` seconds ago, after an earlier good one.
    func writeRuns(failureCode: String, ago: TimeInterval) throws {
        let environment = try CalopodRuntimeEnvironment(
            variables: ["CALOPOD_STATE_PATH": state.path],
            stateLocation: CalopodStateLocation(environment: ["CALOPOD_STATE_PATH": state.path]),
            executableURL: inside)
        let repository = try environment.repository()
        let good = try repository.beginSyncRun(mode: "apply", trigger: "automatic", id: "a", now: Date(timeIntervalSinceNow: -ago - 600))
        try repository.finishSyncRun(id: good, status: "succeeded", now: Date(timeIntervalSinceNow: -ago - 590))
        let bad = try repository.beginSyncRun(mode: "apply", trigger: "automatic", id: "b", now: Date(timeIntervalSinceNow: -ago - 5))
        try repository.finishSyncRun(id: bad, status: "failed", errorCode: failureCode, now: Date(timeIntervalSinceNow: -ago))
    }
}

@Test
func aLinkedCommandFindsTheAppItIsInside() throws {
    let world = try World()
    defer { world.remove() }
    let found = AppServiceLocator.enclosingApp(of: world.link)
    #expect(found == world.app.resolvingSymlinksInPath())
    #expect(AppServiceLocator.enclosingApp(of: URL(fileURLWithPath: "/usr/bin/true")) == nil)
}

@Test("Which service is live", arguments: [
    // (mainBundleIsApp, registration, appLoaded, expectLive)
    (true, BackgroundServiceState.enabled, false, true),
    (true, BackgroundServiceState.requiresApproval, false, false),
    (false, BackgroundServiceState.enabled, false, false),
    (false, BackgroundServiceState.enabled, true, true),
    (true, BackgroundServiceState.notFound, true, true),
])
func registrationIsAskedOnlyWhenThisProcessIsTheApp(
    isApp: Bool, registration: BackgroundServiceState, loaded: Bool, live: Bool
) throws {
    let world = try World()
    defer { world.remove() }
    let resolution = AppServiceLocator.resolve(
        executableURL: world.link,
        mainBundleURL: isApp ? world.app : world.root,
        registration: { registration },
        launchd: { LaunchdService(loaded: loaded, program: nil) })
    #expect(resolution.isLive == live)
    #expect(resolution.registration == (isApp ? registration : nil))
    #expect(resolution.agentExecutable == (live ? world.app.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/calopod-agent") : nil))
}

@Test
func aCommandOutsideAnyAppStillReportsTheLoadedAppService() {
    let resolution = AppServiceLocator.resolve(
        executableURL: URL(fileURLWithPath: "/example/bin/calopod"),
        mainBundleURL: URL(fileURLWithPath: "/example/bin"),
        registration: { .enabled },
        launchd: { LaunchdService(loaded: true, program: URL(fileURLWithPath: appProgram)) })
    #expect(resolution.isLive && resolution.registration == nil)
    #expect(resolution.agentExecutable?.path == appProgram)
}

@Test
func launchctlOutputGivesTheProgram() {
    let output = "pro.elijahquintana.calopod.app-agent = {\n\tstate = running\n\tprogram = \(appProgram)\n}"
    #expect(AppServiceLocator.parseProgram(fromLaunchctlPrint: output)?.path == appProgram)
    #expect(AppServiceLocator.parseProgram(fromLaunchctlPrint: "state = running") == nil)
}

@Test
func linkedCommandWithLaunchdLoadedDescribesTheAppService() throws {
    let world = try World(sourceInstalled: true)
    defer { world.remove() }
    try world.writeRuns(failureCode: "target-refresh", ago: 4184)
    try AgentScheduleOverride(intervalSeconds: 900).save(to: CalopodStateLocation(environment: ["CALOPOD_STATE_PATH": world.state.path]))

    // Launched through the link, so the bundle is not the app and SMAppService cannot answer.
    let service = world.service(from: world.link, appLoaded: true, sourceLoaded: false)
    let status = try service.statusPayload()

    #expect(status.service == "the Calopod app's background service")
    #expect(status.sourceInstall == nil)
    #expect(status.enabled == true && status.runState == "running")
    #expect(status.intervalSeconds == 900)
    #expect(status.lookbackDays == AgentScheduleDefaults.lookbackDays && status.horizonDays == AgentScheduleDefaults.horizonDays)
    #expect(status.failureCategory == "target-refresh" && status.status == "failed")
    #expect(status.message.contains("could not read the target calendars"))
    #expect(status.lastRunStatus == "failed")
    #expect(abs((status.lastRunAgeSeconds ?? 0) - 4184) < 30)
    #expect(abs((status.lastSuccessAgeSeconds ?? 0) - 4784) < 30)
    let text = try OutputRenderer.render(command: "agent.status", payload: status, format: .human)
    #expect(text.contains("Service: the Calopod app's background service"))
    #expect(text.contains("Failed step: could not read the target calendars"))
}

@Test
func registeredAppWithoutLaunchdStillCountsWhenRunInsideTheApp() throws {
    let world = try World()
    defer { world.remove() }
    let service = world.service(from: world.inside, mainBundle: world.app, registration: .enabled, appLoaded: false)
    let status = try service.statusPayload()
    #expect(status.service == "the Calopod app's background service")
    #expect(status.enabled == true && status.runState == "stopped")
}

@Test
func sourceOnlyIsDescribedAsTheOldSourceInstall() throws {
    let world = try World(sourceInstalled: true)
    defer { world.remove() }
    let status = try world.service(from: world.link, sourceLoaded: true).statusPayload()
    #expect(status.service == "the old source install")
    #expect(status.sourceInstall == nil)
    #expect(status.runState == "running" && status.intervalSeconds == 300)
}

@Test
func bothLoadedReportsTheAppAndMentionsTheSourceInstall() throws {
    let world = try World(sourceInstalled: true)
    defer { world.remove() }
    let service = world.service(from: world.link, appLoaded: true, sourceLoaded: true)
    let status = try service.statusPayload()
    #expect(status.service == "the Calopod app's background service")
    #expect(status.sourceInstall?.contains("still loaded") == true)
    let items = try service.doctor().items
    #expect(items.contains { $0.id == "service-in-use" && $0.label == "the Calopod app's background service" })
    #expect(items.contains { $0.id == "source-install" })
}

@Test
func neitherServiceMeansNotInstalled() throws {
    let world = try World()
    defer { world.remove() }
    let service = world.service(from: world.link)
    #expect(try service.statusPayload().status == "not-installed")
    #expect(try service.doctor().items.contains { $0.id == "installation" && $0.reason == "not-installed" })
}

@Test
func doctorUsesTheAppsHelperAndNamesTheLastFailedRun() throws {
    let world = try World(sourceInstalled: true)
    defer { world.remove() }
    try world.writeRuns(failureCode: "target-refresh", ago: 4184)
    let service = world.service(from: world.link, appLoaded: true)

    let host = world.app.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/eventkit-host/Calopod EventKit Host.app")
    #expect(try service.calendarAccess.hostURL() == host)
    let report = try service.doctor()
    #expect(!report.items.contains { $0.label?.contains("/example/source") == true })
    let failed = try #require(report.items.first { $0.id == "automatic-run" })
    #expect(failed.reason == "target-refresh")
    #expect(failed.label == "could not read the target calendars, 69 minutes ago")
}

@Test
func disabledAppServiceReadsAsOffFromTheRegistration() throws {
    let world = try World()
    defer { world.remove() }
    let service = world.service(from: world.inside, mainBundle: world.app, registration: .requiresApproval, appLoaded: false)
    // Not enabled and not loaded: the app's service is not the live one, so nothing is reported for it.
    #expect(try service.statusPayload().status == "not-installed")
}

@Test
func failureStepsUsePlainWords() {
    #expect(FailureStep.description(for: "target-refresh") == "could not read the target calendars")
    #expect(FailureStep.description(for: "source-refresh") == "could not read the source calendars")
    #expect(FailureStep.ago(4184) == "69 minutes")
    #expect(FailureStep.ago(1) == "1 second")
}
#endif
