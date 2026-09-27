#if os(macOS)
import CalopodEventKit
import Foundation

struct EventKitHostRunner {
    private let appURL: URL

    init(environment: CalopodRuntimeEnvironment) throws {
        appURL = try Self.resolveAppURL(
            variables: environment.variables,
            executableURL: environment.executableURL
        )
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CalopodRuntimeError.missingEventKitHost
        }
    }

    static func resolveAppURL(
        variables: [String: String],
        executableURL: URL
    ) throws -> URL {
        if let configured = variables["CALOPOD_EVENTKIT_HOST_APP"], !configured.isEmpty {
            guard configured.hasPrefix("/") else {
                throw CalopodRuntimeError.invalidEventKitHostPath
            }
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        var ancestor = executableURL.deletingLastPathComponent()
        while ancestor.path != "/" {
            let candidate = ancestor
                .appendingPathComponent("eventkit-host", isDirectory: true)
                .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
            let buildCandidate = ancestor
                .appendingPathComponent(".build/eventkit-host", isDirectory: true)
                .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: buildCandidate.path) {
                return buildCandidate.standardizedFileURL
            }
            ancestor.deleteLastPathComponent()
        }
        throw CalopodRuntimeError.missingEventKitHost
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
            throw CalopodRuntimeError.eventKitHostFailed
        }
        process.waitUntilExit()
        try? launcherStderr.close()

        let data = try Data(contentsOf: stdoutURL)
        guard let response = try? JSONDecoder().decode(EventKitHostResponse.self, from: data) else {
            throw CalopodRuntimeError.eventKitHostFailed
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
