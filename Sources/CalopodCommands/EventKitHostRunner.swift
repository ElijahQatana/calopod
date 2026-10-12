#if os(macOS)
import CalopodEventKit
import CalopodRuntime
import Foundation

/// Launches the EventKit Host app from an interactive CLI invocation.
/// Without `CALOPOD_EVENTKIT_HOST_APP` set, the host path is resolved from
/// the running executable. That supports both repository builds and the
/// packaged per-user layout without depending on the current directory.
struct EventKitHostRunner {
    private let appURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) throws {
        appURL = try Self.resolveAppURL(
            environment: environment,
            executableURL: executableURL
        )
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CommandEnvironmentError.missingEventKitHost
        }
    }

    static func resolveAppURL(
        environment: [String: String],
        executableURL: URL
    ) throws -> URL {
        if let configured = environment["CALOPOD_EVENTKIT_HOST_APP"], !configured.isEmpty {
            guard configured.hasPrefix("/") else {
                throw CommandEnvironmentError.invalidEventKitHostPath
            }
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        var ancestor = executableURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        while ancestor.path != "/" {
            let packaged = ancestor
                .appendingPathComponent("eventkit-host", isDirectory: true)
                .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: packaged.path) {
                return packaged.standardizedFileURL
            }
            let development = ancestor
                .appendingPathComponent(".build/eventkit-host", isDirectory: true)
                .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: development.path) {
                return development.standardizedFileURL
            }
            ancestor.deleteLastPathComponent()
        }
        throw CommandEnvironmentError.missingEventKitHost
    }

    func requestPermission() throws -> EventKitHostResponse {
        try runApp(arguments: ["--request-permission"])
    }

    func perform(_ request: EventKitHostRequest) throws -> EventKitHostResponse {
        let data = try JSONEncoder().encode(request)
        return try runApp(arguments: [], requestData: data)
    }

    private func runApp(
        arguments: [String],
        requestData: Data? = nil
    ) throws -> EventKitHostResponse {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-eventkit-\(UUID().uuidString)", isDirectory: true)
        try PrivateFiles.createDirectory(at: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.log")
        let launcherStderrURL = temporaryDirectory.appendingPathComponent("launcher-stderr.log")
        try PrivateFiles.createFile(at: stdoutURL)
        try PrivateFiles.createFile(at: stderrURL)
        try PrivateFiles.createFile(at: launcherStderrURL)

        var appArguments = arguments
        if let requestData {
            let requestURL = temporaryDirectory.appendingPathComponent("request.json")
            try PrivateFiles.createFile(at: requestURL, contents: requestData)
            appArguments.append(contentsOf: ["--request-file", requestURL.path])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-W", "-n",
            "--stdout", stdoutURL.path,
            "--stderr", stderrURL.path,
            appURL.path,
            "--args",
        ]
        process.arguments?.append(contentsOf: appArguments)
        let launcherStderr = try FileHandle(forWritingTo: launcherStderrURL)
        process.standardError = launcherStderr
        do {
            try process.run()
        } catch {
            try? launcherStderr.close()
            throw CommandEnvironmentError.eventKitHostFailed
        }
        process.waitUntilExit()
        try? launcherStderr.close()

        let data = try Data(contentsOf: stdoutURL)
        guard let response = try? JSONDecoder().decode(EventKitHostResponse.self, from: data) else {
            throw CommandEnvironmentError.eventKitHostFailed
        }
        return response
    }
}
#endif
