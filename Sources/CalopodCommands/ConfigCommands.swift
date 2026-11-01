import ArgumentParser
import CalopodStore
import Foundation

public struct ConfigCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Save your setup to a file, or load it on another Mac.",
        subcommands: [ConfigExportCommand.self, ConfigImportCommand.self]
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

public struct ConfigImportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Show what a settings file would change, then change it after a yes."
    )

    @Argument(help: "Path to the settings file.")
    public var path: String

    @Flag(name: .long, help: "Show the changes and stop.")
    public var dryRun = false

    @Flag(name: .long, help: "Make the changes without asking.")
    public var yes = false

    public init() {}

    public func run() throws {
        do {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw ValidationError("Can't read \(path).")
            }
            let file = try SettingsFile.decode(data)
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let importer = SettingsImporter(repository: try CommandEnvironment.repository())
            let plan = try importer.plan(file)
            for line in plan.lines { print(line) }
            if plan.lines.isEmpty { print("Nothing to change.") }
            if !plan.missingConnections.isEmpty {
                print("\nSign in again on this Mac and import again for: \(plan.missingConnections.joined(separator: ", "))")
            }
            if !plan.unmatched.isEmpty {
                print("\nNot found here, so left as they are:")
                for item in plan.unmatched { print("  \(item)") }
            }
            if plan.addsArms { print("\n\(SettingsImportPlan.copiesNotice)") }
            if plan.lines.isEmpty || dryRun { return }
            if !yes {
                print("\nMake these changes? [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else {
                    print("Nothing was changed.")
                    return
                }
            }
            let result = importer.apply(plan)
            print("Changes made: \(result.applied) of \(plan.lines.count).")
            for failure in result.failed { print("  Not made: \(failure)") }
        } catch let error as SettingsFileError {
            try failCommand(ValidationError(error.description))
        } catch {
            try failCommand(error)
        }
    }
}
