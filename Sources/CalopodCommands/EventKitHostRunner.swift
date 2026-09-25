#if os(macOS)
import CalopodEventKit
import Foundation

struct EventKitHostRunner {
    private let appURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let configured = environment["CALOPOD_EVENTKIT_HOST_APP"], !configured.isEmpty {
            appURL = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            appURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/eventkit-host/Calopod EventKit Host.app")
        }
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CommandEnvironmentError.missingEventKitHost
        }
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
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporaryDirectory.path
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.log")
        let launcherStderrURL = temporaryDirectory.appendingPathComponent("launcher-stderr.log")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: launcherStderrURL.path, contents: nil)
        try setPrivatePermissions(on: stdoutURL)
        try setPrivatePermissions(on: stderrURL)
        try setPrivatePermissions(on: launcherStderrURL)

        var appArguments = arguments
        if let requestData {
            let requestURL = temporaryDirectory.appendingPathComponent("request.json")
            try requestData.write(to: requestURL, options: .atomic)
            try setPrivatePermissions(on: requestURL)
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

    private func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
#endif
