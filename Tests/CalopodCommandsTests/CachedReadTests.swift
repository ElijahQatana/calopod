@testable import CalopodCommands
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Test
func cachedCalendarAndInboxReadsProceedUnderSyncLock() async throws {
    let fixture = try CachedStateFixture()
    defer { fixture.remove() }
    let holder = Process()
    let input = Pipe()
    let output = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = ["-c", "import fcntl, sys; f = open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX); sys.stdout.write('1'); sys.stdout.flush(); sys.stdin.read()", fixture.environment.stateLocation.lockURL.path]
    holder.standardInput = input
    holder.standardOutput = output
    try holder.run()
    defer {
        try? input.fileHandleForWriting.close()
        holder.waitUntilExit()
    }
    try #require(try output.fileHandleForReading.read(upToCount: 1) == Data("1".utf8))
    let read = try await calendarCommandRead(environment: fixture.environment, cached: true,
        connectionID: nil, calendarID: nil, range: fixture.range, readSource: { _, _, _ in
            Issue.record("A cached read must not access a provider")
            throw CalopodRuntimeError.sourceRefreshFailed
        })
    defer { withExtendedLifetime(read) {} }
    #expect(read.sources.map(\.calendar.id) == ["calendar"])
    #expect(read.refresh.refreshedSourceCount == 0)
    #expect(!read.refresh.warnings.isEmpty)
    let events = try read.repository.normalizedInstances(calendarBindingIDs: ["calendar"],
        from: fixture.range.window.start, through: fixture.range.window.end)
    #expect(events.map(\.sourceKeyHash) == ["event"])
    #expect(AvailabilityCalculator.calculate(instances: events, from: fixture.range.window.start,
        through: fixture.range.window.end).busy.count == 1)
    let inbox = try InboxCLI.list(repository: read.repository, options: InboxOptions.parse([]), range: nil, activity: false)
    #expect(inbox.items?.map(\.id) == ["event:2"])
    let activity = try InboxCLI.list(repository: read.repository, options: InboxOptions.parse([]), range: nil, activity: true)
    #expect(activity.count == 1)
    #expect(try InboxCLI.inspect("event:2", repository: read.repository).items?.first?.inbox?.reviewed == false)
    await #expect(throws: CalopodRuntimeError.busy) {
        try await calendarCommandRead(environment: fixture.environment, cached: false,
            connectionID: nil, calendarID: nil, range: fixture.range)
    }
    #expect(throws: CalopodRuntimeError.busy) {
        try fixture.environment.restoreState(from: fixture.backupURL.path)
    }
    #expect(try fixture.environment.readOnlyState().repository.connections().count == 1)
}

@Test
func restoreExcludesCachedReadersUntilTheyFinish() throws {
    let fixture = try CachedStateFixture()
    defer { fixture.remove() }
    var read: CalopodStateRead? = try fixture.environment.readOnlyState()
    #expect(throws: CalopodRuntimeError.busy) {
        try fixture.environment.restoreState(from: fixture.backupURL.path)
    }
    #expect(try read?.repository.connections().count == 1)
    read = nil
    #expect(try fixture.environment.restoreState(from: fixture.backupURL.path).migrationCount == 14)
    let restoreLock = try ProcessLock.acquire(at: fixture.environment.stateLocation.accessLockURL)
    defer { withExtendedLifetime(restoreLock) {} }
    #expect(throws: CalopodRuntimeError.busy) { try fixture.environment.readOnlyState() }
}

@Test
func cachedFlagsAreAvailableForBothCalendarReads() throws {
    #expect(try EventsCommand.parse(["--cached"]).cached)
    #expect(try AvailabilityCommand.parse(["--cached"]).cached)
    #expect(try !EventsCommand.parse([]).cached)
    #expect(try !AvailabilityCommand.parse([]).cached)
}

private struct CachedStateFixture {
    let root: URL
    let environment: CalopodRuntimeEnvironment
    let backupURL: URL
    let range: ResolvedDateRange

    init() throws {
        range = ResolvedDateRange(window: try SyncWindow(start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)), timeZoneIdentifier: "UTC")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backupURL = root.appendingPathComponent("backup.sqlite")
        let location = try CalopodStateLocation(environment: ["CALOPOD_STATE_PATH": root.appendingPathComponent("state.sqlite").path])
        environment = try CalopodRuntimeEnvironment(variables: [:], stateLocation: location,
            executableURL: root.appendingPathComponent("calopod"))
        let repository = try environment.repository()
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default",
            provider: "eventkit", displayLabel: "Example", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: [
            StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source",
                displayLabel: "Example", isSelected: true, isReadOnly: true)
        ])
        for title in ["Initial", "Updated"] {
            let event = StoredNormalizedInstance(sourceKeyHash: "event", connectionID: "connection",
                calendarBindingID: "calendar", providerEventID: "event", recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: 110), endsAt: Date(timeIntervalSince1970: 150),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false,
                title: title, contentFingerprint: title, providerUpdatedAt: nil,
                currentUserResponse: EventResponse(state: .needsResponse))
            try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar",
                windowStart: range.window.start, windowEnd: range.window.end, instances: [event],
                cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        }
        _ = try LocalStateBackup.create(from: location.databaseURL.path, at: backupURL.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
