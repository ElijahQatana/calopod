import ArgumentParser
import Foundation

public enum OutputFormat: String, CaseIterable, ExpressibleByArgument, Sendable {
    case human
    case json
}

public struct OutputOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: human or json.")
    public var format: OutputFormat = .human

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

    public init(
        status: String,
        message: String,
        count: Int? = nil,
        range: RangeOutput? = nil,
        mode: String? = nil,
        sources: [CommandSource]? = nil,
        items: [CommandItem]? = nil
    ) {
        self.status = status
        self.message = message
        self.count = count
        self.range = range
        self.mode = mode
        self.sources = sources
        self.items = items
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
        enabled: Bool? = nil
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
        format: OutputFormat
    ) throws -> String {
        switch format {
        case .human:
            var lines = [payload.message]
            if let count = payload.count {
                lines.append("Count: \(count)")
            }
            if let mode = payload.mode {
                lines.append("Mode: \(mode)")
            }
            if let range = payload.range {
                lines.append("From: \(range.start)")
                lines.append("Through: \(range.endExclusive) (exclusive)")
                lines.append("Timezone: \(range.timezone)")
            }
            if let sources = payload.sources {
                lines.append("Sources: \(sources.count)")
                lines.append(contentsOf: sources.map {
                    [$0.id, $0.label, $0.provider].compactMap { $0 }.joined(separator: "  ")
                })
            }
            if let items = payload.items {
                lines.append(contentsOf: items.map { item in
                    var details = [item.id, item.label].compactMap { $0 }
                    if item.selected == true { details.append("selected") }
                    if item.readOnly == true { details.append("read only") }
                    if let startsAt = item.startsAt { details.append(startsAt) }
                    if let endsAt = item.endsAt { details.append("to \(endsAt)") }
                    if item.allDay == true { details.append("all day") }
                    if item.cancelled == true { details.append("cancelled") }
                    if let availability = item.availability { details.append(availability) }
                    if let sourceType = item.sourceType { details.append(sourceType) }
                    if let sourceLabel = item.sourceLabel { details.append(sourceLabel) }
                    if let sourceIDs = item.sourceIDs { details.append("sources: \(sourceIDs.joined(separator: ", "))") }
                    if let targetID = item.targetID { details.append("target: \(targetID)") }
                    if let rule = item.rule { details.append("rule: \(rule)") }
                    if let enabled = item.enabled { details.append(enabled ? "enabled" : "disabled") }
                    return details.joined(separator: "  ")
                })
            }
            lines.append(contentsOf: warnings.map { "Warning: \($0)" })
            return lines.joined(separator: "\n")

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
        format: OutputFormat
    ) throws {
        print(try render(command: command, payload: payload, warnings: warnings, format: format))
    }
}
