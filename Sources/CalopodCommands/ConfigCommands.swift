import ArgumentParser
import CalopodStore
import Foundation

public struct ConfigCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Save your setup to a file.",
        subcommands: [ConfigExportCommand.self]
    )

    public init() {}
}

public struct ConfigExportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Print your settings as a file."
    )

    public init() {}

    public func run() throws {
        do {
            let file = try SettingsFile(repository: CommandEnvironment.repository())
            print(String(decoding: try file.encoded(), as: UTF8.self))
            FileHandle.standardError.write(Data("This file has calendar and account names in it. Don't share it.\n".utf8))
        } catch {
            try failCommand(error)
        }
    }
}
