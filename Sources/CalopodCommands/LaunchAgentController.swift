import Foundation

enum LaunchAgentControlError: Error, Equatable {
    case notInstalled
    case rootUnsupported
    case unavailable
    case operationFailed(String)
}

struct LaunchAgentSnapshot: Equatable {
    let installed: Bool
    let loaded: Bool
    let disabled: Bool
    let configuration: AgentServiceConfiguration?
}

struct LaunchctlResult: Equatable {
    let exitCode: Int32
    let output: String
}

#if os(macOS)
import Darwin

struct LaunchAgentController {
    typealias Launchctl = ([String]) throws -> LaunchctlResult

    private let homeDirectory: URL
    private let userID: uid_t
    private let fileManager: FileManager
    private let launchctl: Launchctl

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        fileManager: FileManager = .default,
        launchctl: @escaping Launchctl = LaunchAgentController.runLaunchctl
    ) throws {
        guard userID != 0 else { throw LaunchAgentControlError.rootUnsupported }
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.userID = userID
        self.fileManager = fileManager
        self.launchctl = launchctl
    }

    var propertyListURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(AgentServiceConfiguration.label).plist")
    }

    func snapshot() throws -> LaunchAgentSnapshot {
        guard fileManager.fileExists(atPath: propertyListURL.path) else {
            return LaunchAgentSnapshot(
                installed: false,
                loaded: false,
                disabled: false,
                configuration: nil
            )
        }
        return LaunchAgentSnapshot(
            installed: true,
            loaded: try isLoaded(),
            disabled: try isDisabled(),
            configuration: try AgentServiceConfiguration.load(from: propertyListURL)
        )
    }

    func enable() throws {
        _ = try installedConfiguration()
        try requireSuccess(launchctl(["enable", serviceTarget]), operation: "enable")
        if try !isLoaded() {
            try requireSuccess(
                launchctl(["bootstrap", launchDomain, propertyListURL.path]),
                operation: "bootstrap"
            )
        }
    }

    func disable() throws {
        _ = try installedConfiguration()
        if try isLoaded() {
            try requireSuccess(launchctl(["bootout", serviceTarget]), operation: "bootout")
        }
        try requireSuccess(launchctl(["disable", serviceTarget]), operation: "disable")
    }

    func restartIfEnabled() throws {
        _ = try installedConfiguration()
        if try isLoaded() {
            try requireSuccess(launchctl(["bootout", serviceTarget]), operation: "bootout")
        }
        if try !isDisabled() {
            try requireSuccess(
                launchctl(["bootstrap", launchDomain, propertyListURL.path]),
                operation: "bootstrap"
            )
        }
    }

    private var launchDomain: String {
        "gui/\(userID)"
    }

    private var serviceTarget: String {
        "\(launchDomain)/\(AgentServiceConfiguration.label)"
    }

    private func installedConfiguration() throws -> AgentServiceConfiguration {
        guard fileManager.fileExists(atPath: propertyListURL.path) else {
            throw LaunchAgentControlError.notInstalled
        }
        return try AgentServiceConfiguration.load(from: propertyListURL)
    }

    private func isLoaded() throws -> Bool {
        try launchctl(["print", serviceTarget]).exitCode == 0
    }

    private func isDisabled() throws -> Bool {
        let result = try launchctl(["print-disabled", launchDomain])
        guard result.exitCode == 0 else {
            throw LaunchAgentControlError.operationFailed("status")
        }
        return result.output.contains("\"\(AgentServiceConfiguration.label)\" => true")
    }

    private func requireSuccess(
        _ result: LaunchctlResult,
        operation: String
    ) throws {
        guard result.exitCode == 0 else {
            throw LaunchAgentControlError.operationFailed(operation)
        }
    }

    private static func runLaunchctl(arguments: [String]) throws -> LaunchctlResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LaunchAgentControlError.unavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return LaunchctlResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
#endif
