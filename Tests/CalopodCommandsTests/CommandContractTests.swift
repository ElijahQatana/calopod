@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Test
func rootExposesThePlannedCommandGroups() {
    var names: [String] = []
    for command in CalopodRoot.configuration.subcommands {
        names.append(command.configuration.commandName ?? "")
    }

    #expect(names == [
        "connection",
        "calendars",
        "arm",
        "main",
        "events",
        "join",
        "inbox",
        "notifications",
        "availability",
        "hours",
        "iphone",
        "update",
        "sync",
        "doctor",
        "agent",
        "support",
    ])
}

@Test
func supportExposesSanitizedExportAndBackupCommands() throws {
    let names = SupportCommand.configuration.subcommands.map {
        $0.configuration.commandName ?? ""
    }
    #expect(names == ["export", "backup", "verify", "restore"])

    let export = try SupportExportCommand.parse(["--format", "json"])
    let backup = try SupportBackupCommand.parse([
        "--output", "/example/backup.sqlite",
        "--format", "json",
    ])
    let verify = try SupportVerifyCommand.parse([
        "--backup", "/example/backup.sqlite",
        "--format", "json",
    ])
    let restore = try SupportRestoreCommand.parse([
        "--backup", "/example/backup.sqlite",
        "--confirm",
        "--format", "json",
    ])

    #expect(export.output.format == .json)
    #expect(backup.outputPath == "/example/backup.sqlite")
    #expect(verify.backupPath == "/example/backup.sqlite")
    #expect(restore.confirm)
    #expect(throws: (any Error).self) {
        try SupportRestoreCommand.parse(["--backup", "/example/backup.sqlite"])
    }
}

@Test
func supportConfigurationContainsOnlyAggregateCounts() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let connection = StoredConnection(
        id: "synthetic-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Private label",
        isEnabled: true
    )
    try repository.saveConnection(connection)
    try repository.replaceCalendarBindings(
        connectionID: connection.id,
        bindings: [
            StoredCalendarBinding(
                id: "source",
                connectionID: connection.id,
                providerCalendarID: "private-provider-id",
                displayLabel: "Private calendar",
                isSelected: true,
                isReadOnly: false
            ),
            StoredCalendarBinding(
                id: "target",
                connectionID: connection.id,
                providerCalendarID: "private-target-id",
                displayLabel: "Private target",
                isSelected: false,
                isReadOnly: false
            ),
        ]
    )
    try repository.saveArm(
        StoredArm(
            id: "arm",
            configurationID: "default",
            sourceBindingIDs: ["source"],
            targetBindingID: "target",
            ruleMode: .busy,
            name: "Private Arm name"
        )
    )

    let counts = try supportConfigurationCounts(repository: repository)

    #expect(counts.connectionCount == 1)
    #expect(counts.enabledConnectionCount == 1)
    #expect(counts.selectedCalendarCount == 1)
    #expect(counts.armCount == 1)
    #expect(counts.enabledArmCount == 1)
    #expect(!counts.mainConfigured)
    #expect(counts.busyArmCount == 1)
}

@Test
func agentExposesExplicitControlCommands() {
    let names = AgentCommand.configuration.subcommands.map {
        $0.configuration.commandName ?? ""
    }

    #expect(names == [
        "enable",
        "disable",
        "pause",
        "resume",
        "interval",
        "run-now",
        "status",
    ])

    let status = try? AgentStatusCommand.parse(["--format", "json"])
    let runNow = try? AgentRunNowCommand.parse(["--format", "json"])
    let interval = try? AgentIntervalCommand.parse([
        "--seconds", "900",
        "--jitter-seconds", "45",
        "--lookback-days", "2",
        "--horizon-days", "21",
        "--format", "json",
    ])
    #expect(status?.output.format == .json)
    #expect(runNow?.output.format == .json)
    #expect(interval?.seconds == 900)
    #expect(interval?.jitterSeconds == 45)
    #expect(interval?.lookbackDays == 2)
    #expect(interval?.horizonDays == 21)
    #expect(interval?.output.format == .json)

    #expect(throws: (any Error).self) {
        try AgentIntervalCommand.parse(["--seconds", "0"])
    }
    #expect(throws: (any Error).self) {
        try AgentIntervalCommand.parse(["--seconds", "900", "--lookback-days", "-1"])
    }
    #expect(throws: (any Error).self) {
        try AgentIntervalCommand.parse(["--seconds", "900", "--horizon-days", "0"])
    }
}

@Test
func mainCalendarUsesExplicitSourcesAndTarget() throws {
    let command = try MainConfigureCommand.parse([
        "--source", "source-one",
        "--source", "source-two",
        "--target", "main-target",
        "--format", "json",
    ])

    #expect(command.source == ["source-one", "source-two"])
    #expect(command.target == "main-target")
    #expect(command.output.format == .json)
}

@Test
func armsUseAnExplicitBusyDefaultAndAcceptFullDetails() throws {
    let defaultRule = try ArmAddCommand.parse([
        "--source", "source-one",
        "--target", "target",
    ])
    let fullDetails = try ArmAddCommand.parse([
        "--source", "source-one",
        "--source", "source-two",
        "--target", "target",
        "--rule", "full-details",
    ])

    #expect(defaultRule.rule == .busy)
    #expect(defaultRule.source == ["source-one"])
    #expect(fullDetails.rule == .fullDetails)
    #expect(fullDetails.source == ["source-one", "source-two"])

    let update = try ArmUpdateCommand.parse([
        "synthetic-arm",
        "--rule", "busy",
        "--format", "json",
    ])
    #expect(update.armID == "synthetic-arm")
    #expect(update.rule == .busy)
    #expect(update.output.format == .json)

    let preferredWriter = try ArmUpdateCommand.parse([
        "synthetic-arm",
        "--prefer-current-device",
        "--format", "json",
    ])
    #expect(preferredWriter.rule == nil)
    #expect(preferredWriter.preferCurrentDevice)
}

@Test
func syncDryRunAcceptsAnExplicitBoundedDay() throws {
    let command = try SyncCommand.parse([
        "--dry-run",
        "--day", "2026-09-25",
        "--timezone", "UTC",
        "--format", "json",
    ])

    #expect(command.dryRun)
    #expect(command.range.day == "2026-09-25")
    #expect(command.range.timezone == "UTC")
    #expect(command.output.format == .json)
}

@Test
func syncApplyIsAnExplicitBoundedCommand() throws {
    let command = try SyncCommand.parse([
        "--day", "2026-09-25",
        "--timezone", "UTC",
        "--format", "json",
    ])

    #expect(!command.dryRun)
    #expect(command.range.day == "2026-09-25")
    #expect(command.output.format == .json)
}

@Test
func jsonOutputUsesTheStableEnvelope() throws {
    let resolved = try DateRangeResolver(day: "2026-09-24", timezone: "UTC")
        .resolve(default: .none, systemTimeZone: TimeZone(secondsFromGMT: 0)!)
    let range = try #require(resolved)
    let output = try OutputRenderer.render(
        command: "events",
        payload: CommandPayload(
            status: "ok",
            message: "No events are available.",
            count: 0,
            range: RangeOutput(range: range),
            sources: [
                CommandSource(
                    id: "synthetic-calendar",
                    connectionID: "synthetic-connection",
                    provider: "eventkit",
                    label: "Synthetic calendar"
                ),
            ]
        ),
        format: .json
    )
    let data = try #require(output.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["command"] as? String == "events")
    #expect(object["warnings"] as? [String] == [])
    let payload = try #require(object["data"] as? [String: Any])
    #expect((payload["sources"] as? [[String: Any]])?.count == 1)
}

@Test
func agentOutputContainsOnlyGenericControlAndRunFields() throws {
    let output = try OutputRenderer.render(
        command: "agent.status",
        payload: CommandPayload(
            status: "ok",
            message: "Automatic sync is available.",
            installed: true,
            enabled: true,
            paused: false,
            runState: "running",
            stateReady: true,
            intervalSeconds: 600,
            lastSuccessAgeSeconds: 30,
            failureCategory: nil,
            planned: 4,
            applied: 1,
            warningCount: 0
        ),
        format: .json
    )
    let data = try #require(output.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try #require(object["data"] as? [String: Any])

    #expect(payload["installed"] as? Bool == true)
    #expect(payload["enabled"] as? Bool == true)
    #expect(payload["paused"] as? Bool == false)
    #expect(payload["runState"] as? String == "running")
    #expect(payload["intervalSeconds"] as? Int == 600)
    #expect(payload["planned"] as? Int == 4)
    #expect(payload["failureCategory"] == nil)
}

@Test
func calendarsAcceptExplicitSelectionActions() throws {
    let select = try CalendarsListCommand.parse([
        "--connection", "connection",
        "--select", "calendar",
    ])
    let deselect = try CalendarsListCommand.parse([
        "--connection", "connection",
        "--deselect", "calendar",
    ])

    #expect(select.select == "calendar")
    #expect(select.deselect == nil)
    #expect(deselect.select == nil)
    #expect(deselect.deselect == "calendar")
}

@Test
func likelyEventKitAndDirectProviderOverlapIsBlocked() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let eventKit = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let microsoft = StoredConnection(
        id: "microsoft",
        configurationID: "default",
        provider: "microsoft",
        displayLabel: "Microsoft Calendar",
        isEnabled: true
    )
    try repository.saveConnection(eventKit)
    try repository.saveConnection(microsoft)

    let eventKitBinding = StoredCalendarBinding(
        id: "eventkit-calendar",
        connectionID: eventKit.id,
        providerCalendarID: "eventkit-provider-calendar",
        displayLabel: "Synthetic work calendar",
        isSelected: false,
        isReadOnly: false,
        providerSourceID: "eventkit-source",
        providerSourceType: "exchange",
        providerSourceLabel: "Synthetic work source"
    )
    let microsoftBinding = StoredCalendarBinding(
        id: "microsoft-calendar",
        connectionID: microsoft.id,
        providerCalendarID: "microsoft-provider-calendar",
        displayLabel: "Synthetic work calendar",
        isSelected: true,
        isReadOnly: false
    )
    try repository.replaceCalendarBindings(
        connectionID: eventKit.id,
        bindings: [eventKitBinding]
    )
    try repository.replaceCalendarBindings(
        connectionID: microsoft.id,
        bindings: [microsoftBinding]
    )

    let message = try CalendarSelectionSafety.conflictMessage(
        selecting: eventKitBinding,
        on: eventKit,
        repository: repository
    )

    #expect(message?.contains("Microsoft Calendar") == true)
}

@Test
func likelyDirectProviderAndEventKitOverlapIsBlocked() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let eventKit = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let google = StoredConnection(
        id: "google",
        configurationID: "default",
        provider: "google",
        displayLabel: "Google Calendar",
        isEnabled: true
    )
    try repository.saveConnection(eventKit)
    try repository.saveConnection(google)

    let eventKitBinding = StoredCalendarBinding(
        id: "eventkit-calendar",
        connectionID: eventKit.id,
        providerCalendarID: "eventkit-provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: true,
        isReadOnly: false,
        providerSourceID: "eventkit-source",
        providerSourceType: "caldav",
        providerSourceLabel: "Google"
    )
    let googleBinding = StoredCalendarBinding(
        id: "google-calendar",
        connectionID: google.id,
        providerCalendarID: "google-provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: false,
        isReadOnly: false
    )
    try repository.replaceCalendarBindings(
        connectionID: eventKit.id,
        bindings: [eventKitBinding]
    )
    try repository.replaceCalendarBindings(
        connectionID: google.id,
        bindings: [googleBinding]
    )

    let message = try CalendarSelectionSafety.conflictMessage(
        selecting: googleBinding,
        on: google,
        repository: repository
    )

    #expect(message?.contains("Google Calendar") == true)
}

@Test
func eventReadsRequireASelectedCalendar() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let connection = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let binding = StoredCalendarBinding(
        id: "calendar",
        connectionID: connection.id,
        providerCalendarID: "provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: false,
        isReadOnly: false
    )
    try repository.saveConnection(connection)
    try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [binding])

    var didThrow = false
    do {
        _ = try selectedCalendarBinding(
            id: binding.id,
            connectionID: connection.id,
            repository: repository
        )
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test
func combinedReadsUseEverySelectedCalendarInStableOrder() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let firstConnection = StoredConnection(
        id: "first-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let secondConnection = StoredConnection(
        id: "second-connection",
        configurationID: "default",
        provider: "google",
        displayLabel: "Google Calendar",
        isEnabled: true
    )
    try repository.saveConnection(firstConnection, now: Date(timeIntervalSince1970: 1))
    try repository.saveConnection(secondConnection, now: Date(timeIntervalSince1970: 2))
    try repository.replaceCalendarBindings(
        connectionID: firstConnection.id,
        bindings: [
            StoredCalendarBinding(
                id: "first-selected",
                connectionID: firstConnection.id,
                providerCalendarID: "provider-first",
                displayLabel: "A synthetic calendar",
                isSelected: true,
                isReadOnly: false
            ),
            StoredCalendarBinding(
                id: "not-selected",
                connectionID: firstConnection.id,
                providerCalendarID: "provider-hidden",
                displayLabel: "Hidden synthetic calendar",
                isSelected: false,
                isReadOnly: false
            ),
        ]
    )
    try repository.replaceCalendarBindings(
        connectionID: secondConnection.id,
        bindings: [
            StoredCalendarBinding(
                id: "second-selected",
                connectionID: secondConnection.id,
                providerCalendarID: "provider-second",
                displayLabel: "B synthetic calendar",
                isSelected: true,
                isReadOnly: false
            ),
        ]
    )

    let all = try selectedCalendarSources(
        connectionID: nil,
        calendarID: nil,
        repository: repository
    )
    let filtered = try selectedCalendarSources(
        connectionID: nil,
        calendarID: "second-selected",
        repository: repository
    )

    #expect(all.map(\.calendar.id) == ["first-selected", "second-selected"])
    #expect(filtered.map(\.calendar.id) == ["second-selected"])
}

@Test
func failedRefreshKeepsCachedEventsAndReturnsAStaleWarning() async throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let connection = StoredConnection(
        id: "connection",
        configurationID: "default",
        provider: "synthetic",
        displayLabel: "Synthetic provider",
        isEnabled: true
    )
    let calendar = StoredCalendarBinding(
        id: "calendar",
        connectionID: connection.id,
        providerCalendarID: "provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: true,
        isReadOnly: false
    )
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(3_600)
    let cached = StoredNormalizedInstance(
        sourceKeyHash: "source-key",
        connectionID: connection.id,
        calendarBindingID: calendar.id,
        providerEventID: "provider-event",
        recurrenceID: nil,
        startsAt: start,
        endsAt: end,
        isAllDay: false,
        availability: "busy",
        isCancelled: false,
        isPrivate: false,
        title: "Synthetic event",
        contentFingerprint: "fingerprint",
        providerUpdatedAt: nil
    )
    try repository.saveConnection(connection)
    try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
    try repository.applyEventRefresh(
        connectionID: connection.id,
        calendarBindingID: calendar.id,
        windowStart: start,
        windowEnd: end,
        instances: [cached],
        cancelledSourceKeyHashes: [],
        isFullRefresh: true,
        cursorUpdates: []
    )

    let summary = await refreshCalendarSources(
        [CalendarReadSource(connection: connection, calendar: calendar)],
        from: start,
        through: end,
        repository: repository
    )
    let remaining = try repository.normalizedInstances(
        calendarBindingIDs: [calendar.id],
        from: start,
        through: end
    )

    #expect(summary.refreshedSourceCount == 0)
    #expect(summary.failedSourceCount == 1)
    #expect(summary.warnings.count == 1)
    #expect(remaining == [cached])
    #expect(try repository.connectionHealth(connectionID: connection.id)?.status == "stale")
}

@Test
func armCommandsAcceptPrivateNamesAndClearing() throws {
    let add = try ArmAddCommand.parse([
        "--source", "synthetic-source", "--target", "synthetic-target", "--name", "Work hours",
    ])
    let rename = try ArmUpdateCommand.parse(["synthetic-arm", "--name", "Office"])
    let clear = try ArmUpdateCommand.parse(["synthetic-arm", "--name", ""])
    #expect(add.name == "Work hours")
    #expect(rename.name == "Office")
    #expect(clear.name == "")
}

@Test
func commandVersionMatchesTheVersionFile() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
    #expect(CalopodRoot.configuration.version == text.trimmingCharacters(in: .whitespacesAndNewlines))
}
