@testable import CalopodRuntime
import CalopodDomain
import CalopodStore
import Foundation
import Testing

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
