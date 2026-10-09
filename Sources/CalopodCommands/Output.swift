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
    public let migrationCount: Int?
    public let ingestion: EventIngestionSummary?
    public let review: SyncReviewSummary?

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
        migrationCount: Int? = nil,
        ingestion: EventIngestionSummary? = nil,
        review: SyncReviewSummary? = nil
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
        self.migrationCount = migrationCount
        self.ingestion = ingestion
        self.review = review
    }
}

public struct CommandSource: Codable, Equatable, Sendable {
    public let id: String
    public let connectionID: String
    public let provider: String
    public let label: String?

    public init(id: String, connectionID: String, provider: String, label: String?) {
        self.id = id
        self.connectionID = connectionID
        self.provider = provider
        self.label = label
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
    public let reason: String?
    public let armID: String?
    public let mirrorKey: String?
    public let desiredFingerprint: String?

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
        reason: String? = nil,
        armID: String? = nil,
        mirrorKey: String? = nil,
        desiredFingerprint: String? = nil
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
        self.reason = reason
        self.armID = armID
        self.mirrorKey = mirrorKey
        self.desiredFingerprint = desiredFingerprint
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
