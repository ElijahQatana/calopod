import Darwin
import Foundation

/// Log files for the app's background service. A bundled plist cannot name a path under the home
/// folder, so the agent opens the same files the source install writes to when the plist asks.
public enum AgentLogFiles {
    public static let switchName = "CALOPOD_AGENT_LOG_TO_FILES"

    public static func directory(for location: CalopodStateLocation) -> URL {
        location.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Service", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    public static func standardOutputURL(for location: CalopodStateLocation) -> URL {
        directory(for: location).appendingPathComponent("agent.stdout.log")
    }

    public static func standardErrorURL(for location: CalopodStateLocation) -> URL {
        directory(for: location).appendingPathComponent("agent.stderr.log")
    }

    /// Creates the folder and both files, owner-only, if they are missing.
    public static func prepare(for location: CalopodStateLocation) throws {
        let logs = directory(for: location)
        try PrivateFiles.createDirectory(at: logs.deletingLastPathComponent())
        try PrivateFiles.createDirectory(at: logs)
        try PrivateFiles.createFile(at: standardOutputURL(for: location))
        try PrivateFiles.createFile(at: standardErrorURL(for: location))
    }

    /// Sends this process's stdout and stderr to the log files, appending.
    public static func redirectOutput(for location: CalopodStateLocation) throws {
        try prepare(for: location)
        for (url, target) in [(standardOutputURL(for: location), STDOUT_FILENO),
                              (standardErrorURL(for: location), STDERR_FILENO)] {
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CalopodRuntimeError.invalidStatePath }
            dup2(descriptor, target)
            close(descriptor)
        }
    }
}
