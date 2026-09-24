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

    public init(
        status: String,
        message: String,
        count: Int? = nil,
        range: RangeOutput? = nil,
        mode: String? = nil
    ) {
        self.status = status
        self.message = message
        self.count = count
        self.range = range
        self.mode = mode
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
