import ArgumentParser
import CalopodProviders
import Foundation

public struct UpdateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "See whether a newer Calopod is out.",
        subcommands: [UpdateCheckCommand.self],
        defaultSubcommand: UpdateCheckCommand.self
    )

    public init() {}
}

public struct UpdateCheckCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Ask GitHub for the newest release. Nothing is downloaded or installed."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let result = await UpdateCheck().check(current: CalopodRoot.version)
        let (status, message) = Self.describe(result, current: CalopodRoot.version)
        try OutputRenderer.write(
            command: "update.check", payload: CommandPayload(status: status, message: message),
            format: output.format, showIDs: output.ids)
        if case .failed = result { throw ExitCode(CalopodExitCode.temporaryFailure.rawValue) }
    }

    static func describe(_ result: UpdateResult, current: String) -> (status: String, message: String) {
        switch result {
        case .upToDate:
            ("ok", "Calopod \(current) is the newest release.")
        case let .available(version, page):
            ("update-available", "Calopod \(version) is out, and this is \(current). Download it from \(page.absoluteString)")
        case let .failed(reason):
            ("error", reason)
        }
    }
}
