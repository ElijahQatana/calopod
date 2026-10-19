@testable import CalopodRuntime
import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation
import Testing

@Test
func directConnectionsNeedAClientIDInTheServiceEnvironment() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let location = try CalopodStateLocation(environment: ["CALOPOD_STATE_PATH": "/example/state.sqlite"])
    let executable = URL(fileURLWithPath: "/example/calopod-agent")
    let bare = try CalopodRuntimeEnvironment(variables: [:], stateLocation: location, executableURL: executable)
    let configured = try CalopodRuntimeEnvironment(
        variables: [
            "CALOPOD_GOOGLE_CLIENT_ID": "synthetic-google-id",
            "CALOPOD_MICROSOFT_CLIENT_ID": "synthetic-microsoft-id",
        ],
        stateLocation: location,
        executableURL: executable
    )

    #expect(throws: CalopodRuntimeError.missingGoogleClientID) {
        try bare.googleService(repository: repository)
    }
    #expect(throws: CalopodRuntimeError.missingMicrosoftClientID) {
        try bare.microsoftService(repository: repository)
    }
    _ = try configured.googleService(repository: repository)
    _ = try configured.microsoftService(repository: repository)
    #expect(syncFailureCategory(CalopodRuntimeError.missingGoogleClientID) == "client-id")
    #expect(syncFailureCategory(CalopodRuntimeError.missingMicrosoftClientID) == "client-id")
}

@Test
func statePathsMustBeAbsolute() {
    #expect(throws: CalopodRuntimeError.invalidStatePath) {
        try CalopodStateLocation(environment: ["CALOPOD_STATE_PATH": "state.sqlite"])
    }
}

@Test
func overrideStateProtectsFilesWithoutChangingAnExistingParentDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-state-mode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: directory.path
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )

    try state.prepareDatabaseFile()
    let databaseMode = try #require(
        FileManager.default.attributesOfItem(atPath: state.databaseURL.path)[.posixPermissions] as? NSNumber
    )
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    )

    #expect(databaseMode.intValue == 0o600)
    #expect(directoryMode.intValue == 0o755)
}

@Test
func processLockRejectsAnOverlappingWriterAndCanBeReacquired() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-lock-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sync.lock")

    var first: ProcessLock? = try ProcessLock.acquire(at: url)
    #expect(throws: CalopodRuntimeError.busy) {
        try ProcessLock.acquire(at: url)
    }
    #expect(first != nil)
    first = nil
    _ = try ProcessLock.acquire(at: url)
}

@Test
func agentScheduleUsesABoundedWindowAndDeterministicJitter() throws {
    let schedule = try AgentSchedule(
        interval: 600,
        maximumJitter: 30,
        lookbackDays: 2,
        horizonDays: 14
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_788_566_400)
    let window = try schedule.window(containing: now, calendar: calendar)

    #expect(window.start == calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now)))
    #expect(window.end == calendar.date(byAdding: .day, value: 15, to: calendar.startOfDay(for: now)))
    #expect(schedule.delay(randomUnit: 0) == 600)
    #expect(schedule.delay(randomUnit: 0.5) == 615)
    #expect(schedule.delay(randomUnit: 1) == 630)
}

@Test(arguments: 18...24)
func trackedReadWindowCoversTheWeekAndTheNextOnAnyDay(day: Int) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.firstWeekday = 1
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 19, minute: 30))!
    let window = try CalendarReadWindow.containing(now, calendar: calendar)
    let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
    let nextWeek = try #require(calendar.dateInterval(of: .weekOfYear, for: week.end))
    #expect(window.start <= week.start)
    #expect(window.end >= nextWeek.end)
    // A wider plan window is kept, not cut back.
    let plan = try SyncWindow(start: window.start.addingTimeInterval(-86_400), end: window.end.addingTimeInterval(86_400))
    #expect(try CalendarReadWindow.covering(plan, around: now, calendar: calendar) == plan)
}

@Test
func agentScheduleRequiresExplicitRuntimeValues() throws {
    #expect(throws: CalopodRuntimeError.invalidConfiguration("agent-schedule")) {
        try AgentSchedule(environment: [:])
    }
    let schedule = try AgentSchedule(environment: [
        "CALOPOD_AGENT_INTERVAL_SECONDS": "600",
        "CALOPOD_AGENT_JITTER_SECONDS": "30",
        "CALOPOD_AGENT_LOOKBACK_DAYS": "2",
        "CALOPOD_AGENT_HORIZON_DAYS": "14",
    ])
    #expect(schedule.interval == 600)
    #expect(schedule.maximumJitter == 30)
    #expect(schedule.lookbackDays == 2)
    #expect(schedule.horizonDays == 14)
}

#if os(macOS)
@Test(arguments: [false, true])
func runtimeHostResolutionFollowsInstalledCommandSymlinks(relativeLink: Bool) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-installed-host-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = directory.appendingPathComponent("Library/Application Support/Calopod/Service")
    let host = service.appendingPathComponent("eventkit-host/Calopod EventKit Host.app")
    let executable = service.appendingPathComponent("bin/calopod")
    let link = directory.appendingPathComponent(".local/bin/calopod")
    let unrelatedHost = directory.appendingPathComponent(".local/eventkit-host/Calopod EventKit Host.app")
    for path in [host, executable.deletingLastPathComponent(), link.deletingLastPathComponent(), unrelatedHost] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: relativeLink
            ? "../../Library/Application Support/Calopod/Service/bin/calopod"
            : executable.path
    )

    let linked = try EventKitHostRunner.resolveAppURL(variables: [:], executableURL: link)
    let direct = try EventKitHostRunner.resolveAppURL(variables: [:], executableURL: executable)
    #expect(linked == host.standardizedFileURL)
    #expect(linked == direct)

    let overridden = try EventKitHostRunner.resolveAppURL(
        variables: ["CALOPOD_EVENTKIT_HOST_APP": unrelatedHost.path],
        executableURL: link
    )
    #expect(overridden == unrelatedHost.standardizedFileURL)

    try FileManager.default.removeItem(at: host)
    #expect(throws: CalopodRuntimeError.missingEventKitHost) {
        try EventKitHostRunner.resolveAppURL(variables: [:], executableURL: link)
    }
}

@Test
func eventKitHostResolutionUsesAnAbsoluteConfiguredPathOrTheExecutableTree() throws {
    #expect(throws: CalopodRuntimeError.invalidEventKitHostPath) {
        try EventKitHostRunner.resolveAppURL(
            variables: ["CALOPOD_EVENTKIT_HOST_APP": "relative/host.app"],
            executableURL: URL(fileURLWithPath: "/tmp/calopod-agent")
        )
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-host-path-\(UUID().uuidString)", isDirectory: true)
    let host = directory
        .appendingPathComponent(".build/eventkit-host", isDirectory: true)
        .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory
        .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        .appendingPathComponent("calopod-agent")

    let resolved = try EventKitHostRunner.resolveAppURL(
        variables: [:],
        executableURL: executable
    )

    #expect(resolved == host.standardizedFileURL)
}
#endif

@Test
func aNewRunMarksAnUnfinishedRunInterrupted() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let first = try repository.beginSyncRun(
        mode: "apply",
        trigger: "automatic",
        id: "first",
        now: Date(timeIntervalSince1970: 100)
    )
    let second = try repository.beginSyncRun(
        mode: "apply",
        trigger: "automatic",
        id: "second",
        now: Date(timeIntervalSince1970: 200)
    )

    #expect(first == "first")
    #expect(second == "second")
    let latest = try repository.latestSyncRun(trigger: "automatic")
    #expect(latest?.id == "second")
    #expect(latest?.status == "running")
    try repository.finishSyncRun(
        id: second,
        status: "succeeded",
        plannedCount: 4,
        appliedCount: 1,
        reconciledCount: 2,
        noOpCount: 1,
        warningCount: 0,
        now: Date(timeIntervalSince1970: 300)
    )
    let finished = try repository.latestSyncRun(trigger: "automatic")
    #expect(finished?.status == "succeeded")
    #expect(finished?.plannedCount == 4)
    #expect(finished?.appliedCount == 1)
    #expect(finished?.reconciledCount == 2)
    #expect(finished?.noOpCount == 1)
}

@Test
func automaticRunSkipsDisabledConfigurationWithoutProviderAccess() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: state,
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let repository = try environment.repository()
    let connection = StoredConnection(
        id: "disabled-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Synthetic provider",
        isEnabled: false
    )
    try repository.saveConnection(connection)
    let source = StoredCalendarBinding(
        id: "synthetic-source",
        connectionID: connection.id,
        providerCalendarID: "source-provider-id",
        displayLabel: "Synthetic source",
        isSelected: true,
        isReadOnly: false
    )
    let target = StoredCalendarBinding(
        id: "synthetic-target",
        connectionID: connection.id,
        providerCalendarID: "target-provider-id",
        displayLabel: "Synthetic target",
        isSelected: false,
        isReadOnly: false
    )
    try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [source, target])
    try repository.saveArm(
        StoredArm(
            id: "synthetic-arm",
            configurationID: "default",
            sourceBindingIDs: [source.id],
            targetBindingID: target.id,
            ruleMode: .busy
        )
    )
    let window = try SyncWindow(
        start: Date(timeIntervalSince1970: 1_788_566_400),
        end: Date(timeIntervalSince1970: 1_788_652_800)
    )

    let result = try await SyncEngine(environment: environment).run(
        SyncRequest(mode: .apply, window: window),
        trigger: .automatic
    )

    #expect(result.status == "ok")
    #expect(result.items.isEmpty)
    #expect(result.warnings == ["Skipped an Arm because one of its Connections is disabled."])
    let stored = try repository.latestSyncRun(trigger: "automatic")
    #expect(stored?.status == "succeeded")
    #expect(stored?.warningCount == 1)
}

@Test
func agentBusyReportContainsOnlyAGenericCategory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-busy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )
    try state.prepareDirectory()
    let lock = try ProcessLock.acquire(at: state.lockURL)
    defer { withExtendedLifetime(lock) {} }
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: state,
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) }
    )

    let report = await runner.runOnce()

    #expect(report.status == "busy")
    #expect(report.failureCategory == "busy")
    #expect(report.planned == 0)
    #expect(report.applied == 0)
    #expect(report.warningCount == 0)
}

@Test
func pausedAgentSkipsAutomaticWorkUntilAnExplicitRun() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-paused-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: state,
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let repository = try environment.repository()
    try repository.setAgentPaused(true)
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) }
    )

    let paused = await runner.runOnce()
    #expect(paused.status == "paused")
    #expect(try repository.latestSyncRun(trigger: "automatic") == nil)

    let explicit = await runner.runOnce(ignorePause: true)
    #expect(explicit.status == "ok")
    #expect(try repository.latestSyncRun(trigger: "automatic")?.status == "succeeded")
}

@Test
func busyAgentAttemptWaitsForTheScheduledDelayBeforeStopping() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-delay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )
    try state.prepareDirectory()
    let lock = try ProcessLock.acquire(at: state.lockURL)
    defer { withExtendedLifetime(lock) {} }
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: state,
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let reports = LockedValues<AgentRunReport>()
    let delays = LockedValues<TimeInterval>()
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
            throw CancellationError()
        }
    )

    await runner.runUntilCancelled { reports.append($0) }

    #expect(reports.values.map(\.status) == ["busy"])
    #expect(delays.values == [615])
}

@Test
func failedAgentAttemptsWaitForTheScheduledDelay() async throws {
    try await verifyAgentFailureWaits(
        ProviderFailure.authorizationRequired,
        category: "authorization"
    )
    try await verifyAgentFailureWaits(
        ProviderFailure.permissionDenied,
        category: "permission"
    )
    try await verifyAgentFailureWaits(
        ProviderFailure.temporaryFailure(retryAfterSeconds: 60),
        category: "temporary"
    )
    try await verifyAgentFailureWaits(
        CalopodRuntimeError.invalidStatePath,
        category: "local-state"
    )
}

@Test
func wakeStartsOneFreshBoundedRunWithoutCatchUp() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-wake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: try CalopodStateLocation(
            environment: [
                "CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path,
            ]
        ),
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let schedule = try AgentSchedule(
        interval: 600,
        maximumJitter: 30,
        lookbackDays: 2,
        horizonDays: 14
    )
    let dates = LockedSequence([
        Date(timeIntervalSince1970: 1_788_566_400),
        Date(timeIntervalSince1970: 1_788_912_000),
    ])
    let windows = LockedValues<SyncWindow>()
    let delays = LockedValues<TimeInterval>()
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: schedule,
        now: { dates.next() },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
            if delays.values.count == 2 {
                throw CancellationError()
            }
        },
        runSync: { request in
            let window = try #require(request.window)
            windows.append(window)
            return SyncExecutionResult(
                status: "ok",
                mode: .apply,
                window: window,
                items: [],
                appliedCount: 0,
                reconciledCount: 0,
                noOpCount: 0,
                warnings: []
            )
        }
    )

    await runner.runUntilCancelled { _ in }

    let firstExpectedWindow = try schedule.window(containing: dates.values[0])
    let secondExpectedWindow = try schedule.window(containing: dates.values[1])
    #expect(windows.values.count == 2)
    #expect(windows.values[0] == firstExpectedWindow)
    #expect(windows.values[1] == secondExpectedWindow)
    #expect(delays.values == [615, 615])
}

@Test
func cancellationDuringAnActiveRunStopsWithoutAnotherReport() async throws {
    let (environment, directory) = try temporaryAgentEnvironment(prefix: "active-cancel")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reports = LockedValues<AgentRunReport>()
    let delays = LockedValues<TimeInterval>()
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
        },
        runSync: { request in
            startedContinuation.yield()
            startedContinuation.finish()
            try await Task.sleep(for: .seconds(60))
            return try successfulAgentResult(for: request)
        }
    )
    let task = Task {
        await runner.runUntilCancelled { reports.append($0) }
    }

    for await _ in started { break }
    task.cancel()
    await task.value

    #expect(reports.values.isEmpty)
    #expect(delays.values.isEmpty)
}

@Test
func cancellationDuringTheScheduledWaitPreventsAnotherRun() async throws {
    let (environment, directory) = try temporaryAgentEnvironment(prefix: "wait-cancel")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reports = LockedValues<AgentRunReport>()
    let runs = LockedValues<Int>()
    let delays = LockedValues<TimeInterval>()
    let (waiting, waitingContinuation) = AsyncStream<Void>.makeStream()
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
            waitingContinuation.yield()
            waitingContinuation.finish()
            try await Task.sleep(for: .seconds(60))
        },
        runSync: { request in
            runs.append(1)
            return try successfulAgentResult(for: request)
        }
    )
    let task = Task {
        await runner.runUntilCancelled { reports.append($0) }
    }

    for await _ in waiting { break }
    task.cancel()
    await task.value

    #expect(reports.values.map(\.status) == ["ok"])
    #expect(runs.values.count == 1)
    #expect(delays.values == [615])
}

private func temporaryAgentEnvironment(
    prefix: String
) throws -> (CalopodRuntimeEnvironment, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let state = try CalopodStateLocation(
        environment: [
            "CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path,
        ]
    )
    return (
        try CalopodRuntimeEnvironment(
            variables: [:],
            stateLocation: state,
            executableURL: directory.appendingPathComponent("calopod-agent")
        ),
        directory
    )
}

private func successfulAgentResult(
    for request: SyncRequest
) throws -> SyncExecutionResult {
    let window = try #require(request.window)
    return SyncExecutionResult(
        status: "ok",
        mode: .apply,
        window: window,
        items: [],
        appliedCount: 0,
        reconciledCount: 0,
        noOpCount: 0,
        warnings: []
    )
}

private func verifyAgentFailureWaits(
    _ error: any Error & Sendable,
    category: String
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: try CalopodStateLocation(
            environment: [
                "CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path,
            ]
        ),
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    let reports = LockedValues<AgentRunReport>()
    let delays = LockedValues<TimeInterval>()
    let runner = CalopodAgentRunner(
        environment: environment,
        schedule: try AgentSchedule(
            interval: 600,
            maximumJitter: 30,
            lookbackDays: 2,
            horizonDays: 14
        ),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
            throw CancellationError()
        },
        runSync: { _ in throw error }
    )

    await runner.runUntilCancelled { reports.append($0) }

    #expect(reports.values.map(\.status) == ["failed"])
    #expect(reports.values.map(\.failureCategory) == [category])
    #expect(delays.values == [615])
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedSequence<Value: Sendable>: @unchecked Sendable {
    let values: [Value]
    private let lock = NSLock()
    private var index = 0

    init(_ values: [Value]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> Value {
        lock.withLock {
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}

private func mode(of url: URL) throws -> Int {
    let value = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    )
    return value.intValue
}

@Test
func privateFilesAreCreatedOwnerOnlyEvenWithAPermissiveUmask() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-private-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = umask(0)
    defer { umask(previous) }

    let directory = root.appendingPathComponent("a/b", isDirectory: true)
    #expect(try PrivateFiles.createDirectory(at: directory))
    #expect(try !PrivateFiles.createDirectory(at: directory))
    #expect(try mode(of: directory) == 0o700)

    let file = directory.appendingPathComponent("request.json")
    try PrivateFiles.createFile(at: file, contents: Data("{}".utf8))
    #expect(try mode(of: file) == 0o600)
    #expect(try Data(contentsOf: file) == Data("{}".utf8))
}

@Test
func newStateDirectoryAndDatabaseSidecarsAreOwnerOnlyWithAPermissiveUmask() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-state-umask-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = umask(0)
    defer { umask(previous) }
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": root.appendingPathComponent("state.sqlite").path]
    )

    try state.prepareDatabaseFile()
    #expect(try mode(of: root) == 0o700)
    #expect(try mode(of: state.databaseURL) == 0o600)

    let database = try CalopodDatabase(path: state.databaseURL.path)
    try database.migrate()
    try database.write { db in
        try db.execute(sql: "CREATE TABLE probe (id INTEGER)")
        try db.execute(sql: "INSERT INTO probe VALUES (1)")
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("state.sqlite-") }
        #expect(!sidecars.isEmpty)
        for name in sidecars {
            #expect(try mode(of: root.appendingPathComponent(name)) == 0o600)
        }
    }
}

// MARK: - Schedule override from the Mac app

private func overrideFixture() throws -> (directory: URL, state: CalopodStateLocation, environment: CalopodRuntimeEnvironment) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-override-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let state = try CalopodStateLocation(
        environment: ["CALOPOD_STATE_PATH": directory.appendingPathComponent("state.sqlite").path]
    )
    try state.prepareDirectory()
    let environment = try CalopodRuntimeEnvironment(
        variables: [:],
        stateLocation: state,
        executableURL: directory.appendingPathComponent("calopod-agent")
    )
    return (directory, state, environment)
}

@Test
func scheduleOverrideRoundTripsOwnerOnlyAndRejectsOutOfRangeValues() throws {
    let fixture = try overrideFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    #expect(AgentScheduleOverride.load(from: fixture.state) == nil)
    try AgentScheduleOverride(intervalSeconds: 900).save(to: fixture.state)
    try AgentScheduleOverride(intervalSeconds: 300).save(to: fixture.state)

    #expect(AgentScheduleOverride.load(from: fixture.state)?.intervalSeconds == 300)
    let mode = try FileManager.default.attributesOfItem(
        atPath: fixture.state.scheduleOverrideURL.path
    )[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(throws: CalopodRuntimeError.self) { try AgentScheduleOverride(intervalSeconds: 59) }
    #expect(throws: CalopodRuntimeError.self) { try AgentScheduleOverride(intervalSeconds: 86_401) }

    try Data(#"{"intervalSeconds":5}"#.utf8).write(to: fixture.state.scheduleOverrideURL)
    #expect(AgentScheduleOverride.load(from: fixture.state) == nil)
    try Data("not json".utf8).write(to: fixture.state.scheduleOverrideURL)
    #expect(AgentScheduleOverride.load(from: fixture.state) == nil)
    AgentScheduleOverride.clear(from: fixture.state)
    #expect(!FileManager.default.fileExists(atPath: fixture.state.scheduleOverrideURL.path))
}

private func delayAfterBusyRun(
    _ fixture: (directory: URL, state: CalopodStateLocation, environment: CalopodRuntimeEnvironment)
) async throws -> [TimeInterval] {
    let lock = try ProcessLock.acquire(at: fixture.state.lockURL)
    defer { withExtendedLifetime(lock) {} }
    let delays = LockedValues<TimeInterval>()
    let runner = CalopodAgentRunner(
        environment: fixture.environment,
        schedule: try AgentSchedule(interval: 600, maximumJitter: 30, lookbackDays: 2, horizonDays: 14),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0.5 },
        sleep: { delay in
            delays.append(delay)
            throw CancellationError()
        }
    )
    await runner.runUntilCancelled { _ in }
    return delays.values
}

@Test
func agentWaitsForTheOverrideIntervalInsteadOfTheInstalledOne() async throws {
    let fixture = try overrideFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try AgentScheduleOverride(intervalSeconds: 300).save(to: fixture.state)

    #expect(try await delayAfterBusyRun(fixture) == [315])
}

@Test
func agentIgnoresAnInvalidOverrideFile() async throws {
    let fixture = try overrideFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try Data("garbage".utf8).write(to: fixture.state.scheduleOverrideURL)

    #expect(try await delayAfterBusyRun(fixture) == [615])
}

@Test
func changingTheOverrideEndsTheCurrentWaitEarly() async throws {
    let fixture = try overrideFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lock = try ProcessLock.acquire(at: fixture.state.lockURL)
    defer { withExtendedLifetime(lock) {} }
    let reports = LockedValues<AgentRunReport>()
    let runner = CalopodAgentRunner(
        environment: fixture.environment,
        schedule: try AgentSchedule(interval: 600, maximumJitter: 0, lookbackDays: 2, horizonDays: 14),
        now: { Date(timeIntervalSince1970: 1_788_566_400) },
        randomUnit: { 0 },
        sleep: { _ in try await Task.sleep(for: .seconds(60)) },
        runSync: { _ in throw CalopodRuntimeError.busy },
        scheduleCheckSeconds: 0.05
    )

    let task = Task { await runner.runUntilCancelled { reports.append($0) } }
    try await Task.sleep(for: .seconds(0.3))
    #expect(reports.values.count == 1)
    try AgentScheduleOverride(intervalSeconds: 120).save(to: fixture.state)
    try await Task.sleep(for: .seconds(0.5))
    task.cancel()
    await task.value

    #expect(reports.values.count >= 2)
}

@Test
func theAppServiceDefaultsMatchTheSourceInstallAndFillGaps() throws {
    let schedule = try AgentSchedule(environment: [:], fillingDefaults: true)
    #expect(schedule.interval == 600)
    #expect(schedule.maximumJitter == 30)
    #expect(schedule.lookbackDays == 7)
    #expect(schedule.horizonDays == 15)
    let given = try AgentSchedule(environment: ["CALOPOD_AGENT_HORIZON_DAYS": "30"], fillingDefaults: true)
    #expect(given.horizonDays == 30)
    #expect(given.lookbackDays == 7)
}

@Test
func theBundledPlistLeavesNumbersToTheDefaultsAndAsksForLogFiles() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/Mac/pro.elijahquintana.calopod.app-agent.plist")
    let values = try #require(
        PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    )
    let environment = try #require(values["EnvironmentVariables"] as? [String: String])
    #expect(environment[AgentLogFiles.switchName] == "1")
    #expect(environment.keys.filter { $0.hasPrefix("CALOPOD_AGENT_") && $0 != AgentLogFiles.switchName }.isEmpty)
}

@Test
func serviceLogsLiveBesideTheStateAndAreCreatedOwnerOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-logs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try CalopodStateLocation(applicationSupportURL: root)

    try AgentLogFiles.prepare(for: location)

    let logs = root.appendingPathComponent("Calopod/Service/logs")
    #expect(AgentLogFiles.standardOutputURL(for: location).path == logs.appendingPathComponent("agent.stdout.log").path)
    #expect(AgentLogFiles.standardErrorURL(for: location).path == logs.appendingPathComponent("agent.stderr.log").path)
    for url in [logs, AgentLogFiles.standardOutputURL(for: location)] {
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0)
    }
}
