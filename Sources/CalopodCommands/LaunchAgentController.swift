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

    /// Pauses before each retry of `bootstrap`. launchd can still be tearing a service down right
    /// after `bootout`, which makes an immediate `bootstrap` fail.
    static let bootstrapRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]

    private let homeDirectory: URL
    private let userID: uid_t
    private let fileManager: FileManager
    private let launchctl: Launchctl
    private let pause: (TimeInterval) -> Void

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        fileManager: FileManager = .default,
        launchctl: @escaping Launchctl = LaunchAgentController.runLaunchctl,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        guard userID != 0 else { throw LaunchAgentControlError.rootUnsupported }
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.userID = userID
        self.fileManager = fileManager
        self.launchctl = launchctl
        self.pause = pause
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
            try bootstrap()
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
            try bootstrap()
        }
    }

    func updateSchedule(
        intervalSeconds: Int,
        jitterSeconds: Int?,
        lookbackDays: Int? = nil,
        horizonDays: Int? = nil
    ) throws {
        guard intervalSeconds > 0,
              jitterSeconds.map({ $0 >= 0 }) ?? true,
              lookbackDays.map({ $0 >= 0 }) ?? true,
              horizonDays.map({ $0 > 0 }) ?? true else {
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
        if let lookbackDays {
            environment["CALOPOD_AGENT_LOOKBACK_DAYS"] = String(lookbackDays)
        }
        if let horizonDays {
            environment["CALOPOD_AGENT_HORIZON_DAYS"] = String(horizonDays)
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
                try? bootstrap()
            }
            throw error
        }
        if wasLoaded, !wasDisabled {
            try bootstrap()
        }
    }

    /// Loads the service, retrying while launchd finishes a preceding `bootout`. A failed attempt
    /// that still leaves the service loaded counts as success.
    private func bootstrap() throws {
        var delays = Self.bootstrapRetryDelays[...]
        while true {
            let result = try launchctl(["bootstrap", launchDomain, propertyListURL.path])
            if result.exitCode == 0 { return }
            if try isLoaded() { return }
            guard let delay = delays.popFirst() else {
                throw LaunchAgentControlError.operationFailed("bootstrap")
            }
            pause(delay)
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

    /// Whether launchd has a service with this label loaded, such as the app's bundled agent.
    func isLoaded(label: String) throws -> Bool {
        try launchctl(["print", "\(launchDomain)/\(label)"]).exitCode == 0
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
