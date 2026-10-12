#if os(macOS)
import CalopodEventKit
import Foundation

/// Launches the EventKit host app and exchanges one request and response. The host is its own
/// signed app because macOS grants Calendar access per process.
struct EventKitHostRunner: Sendable {
    private let appURL: URL
    private let launcherURL: URL
    private let standardLimit: TimeInterval
    private let permissionLimit: TimeInterval
    private let verifyHost: @Sendable (URL) throws -> Void

    /// Lets tests stand in for `open` and shorten the limits.
    init(
        appURL: URL,
        launcherURL: URL,
        standardLimit: TimeInterval,
        permissionLimit: TimeInterval,
        verifyHost: @escaping @Sendable (URL) throws -> Void = EventKitHostSignature.verify(appURL:)
    ) {
        self.appURL = appURL
        self.launcherURL = launcherURL
        self.standardLimit = standardLimit
        self.permissionLimit = permissionLimit
        self.verifyHost = verifyHost
    }

    init(environment: CalopodRuntimeEnvironment) throws {
        appURL = try Self.resolveAppURL(
            variables: environment.variables,
            executableURL: environment.executableURL
        )
        launcherURL = URL(fileURLWithPath: "/usr/bin/open")
        standardLimit = EventKitHostLimits.standard
        permissionLimit = EventKitHostLimits.permissionRequest
        verifyHost = EventKitHostSignature.verify(appURL:)
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CalopodRuntimeError.missingEventKitHost
        }
    }

    /// Finds the host app: an absolute `CALOPOD_EVENTKIT_HOST_APP` first (required for a
    /// LaunchAgent), otherwise searches up from the executable for `eventkit-host` or
    /// `.build/eventkit-host`. Installed symlinks must resolve to the service payload first.
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

    // Talks to the host through files in a fresh owner-only temp directory, since `open` launches
    // it as its own app and there is no pipe. It is removed afterwards.
    private func runApp(
        arguments: [String],
        requestData: Data? = nil,
        limit: TimeInterval
    ) throws -> EventKitHostResponse {
        do {
            try verifyHost(appURL)
        } catch {
            throw CalopodRuntimeError.eventKitHostUntrusted
        }
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
        process.executableURL = launcherURL
        process.arguments = [
            // `-W` waits for the app to exit so the response file is complete; `-n` forces a fresh
            // instance so a running one can't serve a stale request.
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
}
#endif
