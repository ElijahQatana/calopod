#if os(macOS)
import CalopodEventKit
import Foundation

/// Launches the separate EventKit Host app and exchanges one request/response
/// with it. The host runs as its own signed app (not a library linked into
/// this process) because it's the process macOS actually grants or denies
/// Calendar access to — this runner just drives it and reads back the
/// result.
struct EventKitHostRunner {
    private let appURL: URL
    private let launcherURL: URL
    private let standardLimit: TimeInterval
    private let permissionLimit: TimeInterval

    /// Lets tests stand in for `open` and shorten the limits.
    init(
        appURL: URL,
        launcherURL: URL,
        standardLimit: TimeInterval,
        permissionLimit: TimeInterval
    ) {
        self.appURL = appURL
        self.launcherURL = launcherURL
        self.standardLimit = standardLimit
        self.permissionLimit = permissionLimit
    }

    init(environment: CalopodRuntimeEnvironment) throws {
        appURL = try Self.resolveAppURL(
            variables: environment.variables,
            executableURL: environment.executableURL
        )
        launcherURL = URL(fileURLWithPath: "/usr/bin/open")
        standardLimit = EventKitHostLimits.standard
        permissionLimit = EventKitHostLimits.permissionRequest
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CalopodRuntimeError.missingEventKitHost
        }
    }

    /// Finds the EventKit Host app: an explicit, validated absolute path
    /// from `CALOPOD_EVENTKIT_HOST_APP` first (required for a LaunchAgent,
    /// whose working directory can't be relied on), otherwise a search
    /// upward from the resolved executable for packaged `eventkit-host`
    /// or development `.build/eventkit-host` output. Installed command
    /// symlinks must resolve to the service payload before this search.
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

        var ancestor = executableURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
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
        try runApp(
            arguments: ["--request-permission"],
            limit: permissionLimit
        )
    }

    func perform(_ request: EventKitHostRequest) async throws -> EventKitHostResponse {
        let data = try JSONEncoder().encode(request)
        // The launcher wait blocks a thread, so keep it off the cooperative pool.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try runApp(arguments: [], requestData: data, limit: standardLimit)
                })
            }
        }
    }

    // Communicates with the host over a private temp directory of files
    // (request/response/logs) rather than pipes, since the host is launched
    // through `open` as its own app rather than as a direct child process
    // this code controls a pipe to. The directory is created fresh per call,
    // permissioned to the owner only (it can carry calendar content), and
    // always cleaned up afterward.
    private func runApp(
        arguments: [String],
        requestData: Data? = nil,
        limit: TimeInterval
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
        process.executableURL = launcherURL
        process.arguments = [
            // -W waits for the launched app to exit before `open` returns
            // (so the response file is guaranteed complete once this call
            // continues); -n always launches a fresh instance rather than
            // reusing one already running, since a lingering instance could
            // otherwise serve a stale or concurrent request.
            "-W", "-n",
            "--stdout", stdoutURL.path,
            "--stderr", stderrURL.path,
            appURL.path,
            "--args",
        ]
        process.arguments?.append(contentsOf: appArguments)
        let launcherStderr = try FileHandle(forWritingTo: launcherStderrURL)
        process.standardError = launcherStderr
        let finished: Bool
        do {
            finished = try runWithinLimit(process, limit: limit)
        } catch {
            try? launcherStderr.close()
            throw CalopodRuntimeError.eventKitHostFailed
        }
        try? launcherStderr.close()
        guard finished else { throw CalopodRuntimeError.eventKitHostTimedOut }

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
