import ArgumentParser
import CalopodDomain
import Foundation

public enum OutputFormat: String, CaseIterable, ExpressibleByArgument, Sendable {
    case human
    case json
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: human or json.")
    public var format: OutputFormat = .human

    @Flag(name: .long, help: "Include exact identifiers in local human-readable output.")
    public var ids = false

    public init() {}
}

public enum CalopodExitCode: Int32, Sendable {
    case success = 0
    case usage = 64
    case unavailable = 69
    case internalFailure = 70
    case localStateFailure = 74
    case temporaryFailure = 75
    case permissionDenied = 77
    case invalidConfiguration = 78
}

public struct RangeOutput: Codable, Equatable, Sendable {
    public let start: String
    public let endExclusive: String
    public let timezone: String

    public init(range: ResolvedDateRange) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        start = formatter.string(from: range.window.start)
        endExclusive = formatter.string(from: range.window.end)
        timezone = range.timeZoneIdentifier
    }
}

public struct CommandPayload: Codable, Equatable, Sendable {
    public let status: String
    public let message: String
    public let count: Int?
    public let range: RangeOutput?
    public let mode: String?
    public let sources: [CommandSource]?
    public let items: [CommandItem]?
    public let installed: Bool?
    public let enabled: Bool?
    public let paused: Bool?
    public let runState: String?
    public let stateReady: Bool?
    public let intervalSeconds: Int?
    public let jitterSeconds: Int?
    public let lookbackDays: Int?
    public let horizonDays: Int?
    public let lastSuccessAgeSeconds: Int?
    public let failureCategory: String?
    /// Which service the numbers above describe, in words.
    public let service: String?
    /// The old source install, when it is still on next to the app's service.
    public let sourceInstall: String?
    /// How the last automatic run ended, and how long ago.
    public let lastRunStatus: String?
    public let lastRunAgeSeconds: Int?
    public let planned: Int?
    public let applied: Int?
    public let creates: Int?
    public let updates: Int?
    public let removals: Int?
    public let repairs: Int?
    public let noOps: Int?
    public let warningCount: Int?
    public let connectionCount: Int?
    public let enabledConnectionCount: Int?
    public let selectedCalendarCount: Int?
    public let armCount: Int?
    public let enabledArmCount: Int?
    public let mainConfigured: Bool?
    public let busyArmCount: Int?
    public let backupValid: Bool?
    public let backupEncrypted: Bool?
    public let migrationCount: Int?
    public let ingestion: EventIngestionSummary?
    public let review: SyncReviewSummary?
    /// Palette color ids a calendar can be given.
    public let colors: [String]?
    /// Ignored calendars left out of a calendar list. Absent when they are listed.
    public let ignoredCount: Int?
    /// For a Calendar access error: the helper that was asked, its status, and the fix.
    public let helperPath: String?
    public let accessStatus: String?
    public let fix: String?
    /// For `calopod notifications`.
    public let notifications: NotificationSettingsOutput?
    /// For `calopod hours`.
    public let workingHours: WorkingHoursOutput?
    /// For `calopod availability`: the working windows free time was limited to. Absent when
    /// working hours were ignored.
    public let workingWindows: [WorkingWindowOutput]?
    /// For `calopod availability`: seconds free, busy and outside working hours across the range.
    public let totals: AvailabilityTotalsOutput?

    public init(
        status: String,
        message: String,
        count: Int? = nil,
        range: RangeOutput? = nil,
        mode: String? = nil,
        sources: [CommandSource]? = nil,
        items: [CommandItem]? = nil,
        installed: Bool? = nil,
        enabled: Bool? = nil,
        paused: Bool? = nil,
        runState: String? = nil,
        stateReady: Bool? = nil,
        intervalSeconds: Int? = nil,
        jitterSeconds: Int? = nil,
        lookbackDays: Int? = nil,
        horizonDays: Int? = nil,
        lastSuccessAgeSeconds: Int? = nil,
        failureCategory: String? = nil,
        service: String? = nil,
        sourceInstall: String? = nil,
        lastRunStatus: String? = nil,
        lastRunAgeSeconds: Int? = nil,
        planned: Int? = nil,
        applied: Int? = nil,
        creates: Int? = nil,
        updates: Int? = nil,
        removals: Int? = nil,
        repairs: Int? = nil,
        noOps: Int? = nil,
        warningCount: Int? = nil,
        connectionCount: Int? = nil,
        enabledConnectionCount: Int? = nil,
        selectedCalendarCount: Int? = nil,
        armCount: Int? = nil,
        enabledArmCount: Int? = nil,
        mainConfigured: Bool? = nil,
        busyArmCount: Int? = nil,
        backupValid: Bool? = nil,
        backupEncrypted: Bool? = nil,
        migrationCount: Int? = nil,
        ingestion: EventIngestionSummary? = nil,
        review: SyncReviewSummary? = nil,
        colors: [String]? = nil,
        ignoredCount: Int? = nil,
        helperPath: String? = nil,
        accessStatus: String? = nil,
        fix: String? = nil,
        notifications: NotificationSettingsOutput? = nil,
        workingHours: WorkingHoursOutput? = nil,
        workingWindows: [WorkingWindowOutput]? = nil,
        totals: AvailabilityTotalsOutput? = nil
    ) {
        self.status = status
        self.message = message
        self.count = count
        self.range = range
        self.mode = mode
        self.sources = sources
        self.items = items
        self.installed = installed
        self.enabled = enabled
        self.paused = paused
        self.runState = runState
        self.stateReady = stateReady
        self.intervalSeconds = intervalSeconds
        self.jitterSeconds = jitterSeconds
        self.lookbackDays = lookbackDays
        self.horizonDays = horizonDays
        self.lastSuccessAgeSeconds = lastSuccessAgeSeconds
        self.failureCategory = failureCategory
        self.service = service
        self.sourceInstall = sourceInstall
        self.lastRunStatus = lastRunStatus
        self.lastRunAgeSeconds = lastRunAgeSeconds
        self.planned = planned
        self.applied = applied
        self.creates = creates
        self.updates = updates
        self.removals = removals
        self.repairs = repairs
        self.noOps = noOps
        self.warningCount = warningCount
        self.connectionCount = connectionCount
        self.enabledConnectionCount = enabledConnectionCount
        self.selectedCalendarCount = selectedCalendarCount
        self.armCount = armCount
        self.enabledArmCount = enabledArmCount
        self.mainConfigured = mainConfigured
        self.busyArmCount = busyArmCount
        self.backupValid = backupValid
        self.backupEncrypted = backupEncrypted
        self.migrationCount = migrationCount
        self.ingestion = ingestion
        self.review = review
        self.colors = colors
        self.ignoredCount = ignoredCount
        self.helperPath = helperPath
        self.accessStatus = accessStatus
        self.fix = fix
        self.notifications = notifications
        self.workingHours = workingHours
        self.workingWindows = workingWindows
        self.totals = totals
    }
}

public struct CommandSource: Codable, Equatable, Sendable {
    public let id: String
    public let connectionID: String
    public let provider: String
    public let label: String?
    /// The name chosen on this Mac, when there is one. `label` stays the provider's name.
    public let alias: String?
    /// Set only for ignored calendars.
    public let ignored: Bool?
    let inbox: InboxSourceDetail?

    public init(
        id: String, connectionID: String, provider: String, label: String?,
        alias: String? = nil, ignored: Bool? = nil, inbox: InboxSourceDetail? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.provider = provider
        self.label = label
        self.alias = alias
        self.ignored = ignored
        self.inbox = inbox
    }
}

public struct CommandItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let label: String?
    public let parentID: String?
    public let selected: Bool?
    public let readOnly: Bool?
    public let startsAt: String?
    public let endsAt: String?
    public let allDay: Bool?
    public let cancelled: Bool?
    public let availability: String?
    public let sourceType: String?
    public let sourceLabel: String?
    public let sourceIDs: [String]?
    public let targetID: String?
    public let rule: String?
    public let enabled: Bool?
    /// For Arms under the label Rule: the title their copies carry.
    public let armLabel: String?
    /// For Arms that pad their copies, such as "15 min before, 15 min after".
    public let padding: String?
    /// For Arms: the filters that are on, such as "skip-declined".
    public let filters: [String]?
    /// For Arms: "ok", "failing", "never-synced" or "disabled".
    public let syncState: String?
    public let lastSyncAt: String?
    public let lastError: String?
    public let waiting: Int?
    public let reason: String?
    public let armID: String?
    public let mirrorKey: String?
    public let desiredFingerprint: String?
    /// For calendars: the name chosen on this Mac, whether it is ignored, and its palette color.
    public let alias: String?
    public let ignored: Bool?
    public let color: String?
    /// For events with a meeting link: "Teams", "Zoom", "Meet" or "Webex", and the web link.
    public let joinProvider: String?
    public let joinURL: String?
    /// For a copy Calopod made: "full-details" or "busy", and the current user's answer on the original.
    public let copyMode: String?
    public let sourceResponse: String?
    let inbox: InboxItemDetail?

    public init(
        id: String,
        kind: String,
        label: String? = nil,
        parentID: String? = nil,
        selected: Bool? = nil,
        readOnly: Bool? = nil,
        startsAt: String? = nil,
        endsAt: String? = nil,
        allDay: Bool? = nil,
        cancelled: Bool? = nil,
        availability: String? = nil,
        sourceType: String? = nil,
        sourceLabel: String? = nil,
        sourceIDs: [String]? = nil,
        targetID: String? = nil,
        rule: String? = nil,
        enabled: Bool? = nil,
        armLabel: String? = nil,
        padding: String? = nil,
        filters: [String]? = nil,
        syncState: String? = nil,
        lastSyncAt: String? = nil,
        lastError: String? = nil,
        waiting: Int? = nil,
        reason: String? = nil,
        armID: String? = nil,
        mirrorKey: String? = nil,
        desiredFingerprint: String? = nil,
        alias: String? = nil,
        ignored: Bool? = nil,
        color: String? = nil,
        joinProvider: String? = nil,
        joinURL: String? = nil,
        copyMode: String? = nil,
        sourceResponse: String? = nil,
        inbox: InboxItemDetail? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.parentID = parentID
        self.selected = selected
        self.readOnly = readOnly
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.cancelled = cancelled
        self.availability = availability
        self.sourceType = sourceType
        self.sourceLabel = sourceLabel
        self.sourceIDs = sourceIDs
        self.targetID = targetID
        self.rule = rule
        self.enabled = enabled
        self.armLabel = armLabel
        self.padding = padding
        self.filters = filters
        self.syncState = syncState
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.waiting = waiting
        self.reason = reason
        self.armID = armID
        self.mirrorKey = mirrorKey
        self.desiredFingerprint = desiredFingerprint
        self.alias = alias
        self.ignored = ignored
        self.color = color
        self.joinProvider = joinProvider
        self.joinURL = joinURL
        self.copyMode = copyMode
        self.sourceResponse = sourceResponse
        self.inbox = inbox
    }
}

public struct CommandEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let command: String
    public let data: CommandPayload
    public let warnings: [String]

    public init(command: String, data: CommandPayload, warnings: [String] = []) {
        schemaVersion = 1
        self.command = command
        self.data = data
        self.warnings = warnings
    }
}

public enum OutputRenderer {
    public static func render(
        command: String,
        payload: CommandPayload,
        warnings: [String] = [],
        format: OutputFormat,
        showIDs: Bool = false,
        human: HumanOutputContext = HumanOutputContext(),
        width: Int = 80
    ) throws -> String {
        switch format {
        case .human:
            return HumanOutputRenderer.render(
                command: command, payload: payload, warnings: warnings,
                showIDs: showIDs, context: human, width: width
            )

        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(
                CommandEnvelope(command: command, data: payload, warnings: warnings)
            )
            guard let output = String(data: data, encoding: .utf8) else {
                throw ExitCode(CalopodExitCode.internalFailure.rawValue)
            }
            return output
        }
    }

    public static func write(
        command: String,
        payload: CommandPayload,
        warnings: [String] = [],
        format: OutputFormat,
        showIDs: Bool = false,
        human: HumanOutputContext = HumanOutputContext()
    ) throws {
        print(try render(
            command: command, payload: payload, warnings: warnings, format: format,
            showIDs: showIDs, human: human, width: HumanOutputRenderer.terminalWidth
        ))
    }
}
