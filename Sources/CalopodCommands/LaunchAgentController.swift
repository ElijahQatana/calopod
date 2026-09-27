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
        guard try isLoaded(), try !isDisabled() else {
            throw LaunchAgentControlError.operationFailed("enable")
        }
    }

    func disable() throws {
        _ = try installedConfiguration()
        if try isLoaded() {
            try requireSuccess(launchctl(["bootout", serviceTarget]), operation: "bootout")
        }
        try requireSuccess(launchctl(["disable", serviceTarget]), operation: "disable")
        guard try !isLoaded(), try isDisabled() else {
            throw LaunchAgentControlError.operationFailed("disable")
        }
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

    func updateSchedule(intervalSeconds: Int, jitterSeconds: Int?) throws {
        guard intervalSeconds > 0, jitterSeconds.map({ $0 >= 0 }) ?? true else {
            throw AgentServiceConfigurationError.invalidSchedule
        }
        _ = try installedConfiguration()
        let originalData = try Data(contentsOf: propertyListURL)
        guard var propertyList = try PropertyListSerialization.propertyList(
            from: originalData,
            options: [],
            format: nil
        ) as? [String: Any],
        var environment = propertyList["EnvironmentVariables"] as? [String: String] else {
            throw AgentServiceConfigurationError.invalidPropertyList
        }
        environment["CALOPOD_AGENT_INTERVAL_SECONDS"] = String(intervalSeconds)
        if let jitterSeconds {
            environment["CALOPOD_AGENT_JITTER_SECONDS"] = String(jitterSeconds)
        }
        propertyList["EnvironmentVariables"] = environment
        let replacementData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let wasLoaded = try isLoaded()
        let wasDisabled = try isDisabled()
        if wasLoaded {
            try requireSuccess(launchctl(["bootout", serviceTarget]), operation: "bootout")
        }
        do {
            try replacementData.write(to: propertyListURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: propertyListURL.path
            )
            _ = try installedConfiguration()
        } catch {
            try? originalData.write(to: propertyListURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: propertyListURL.path
            )
            if wasLoaded, !wasDisabled {
                _ = try? launchctl(["bootstrap", launchDomain, propertyListURL.path])
            }
            throw error
        }
        if wasLoaded, !wasDisabled {
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
        let label = "\"\(AgentServiceConfiguration.label)\""
        guard let line = result.output.split(separator: "\n").first(where: {
            $0.contains(label)
        }), let separator = line.range(of: "=>") else {
            return false
        }
        let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        return value == "true" || value == "disabled"
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
