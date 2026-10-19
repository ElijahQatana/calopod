#if os(macOS)
import Foundation

public enum EventKitHostLocatorError: Error, Equatable, Sendable {
    case invalidPath
    case missing
}

/// The one place that decides which Calendar helper app a Calopod process talks to. macOS keeps
/// Calendar access per helper copy, so the app, the command and the service must agree.
public enum EventKitHostLocator {
    public static let appName = "Calopod EventKit Host.app"

    /// An absolute `CALOPOD_EVENTKIT_HOST_APP` wins. Otherwise the search starts at the real
    /// executable, so a `~/.local/bin/calopod` link finds the helper in its own app. Inside an app
    /// bundle only that bundle's helper counts; a source install never stands in for it.
    public static func resolve(variables: [String: String], executableURL: URL) throws -> URL {
        if let configured = variables["CALOPOD_EVENTKIT_HOST_APP"], !configured.isEmpty {
            guard configured.hasPrefix("/") else { throw EventKitHostLocatorError.invalidPath }
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        var ancestor = executableURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        while ancestor.path != "/" {
            for relative in ["eventkit-host", ".build/eventkit-host"] {
                let candidate = ancestor
                    .appendingPathComponent(relative, isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
            }
            if ancestor.pathExtension == "app" { break }
            ancestor.deleteLastPathComponent()
        }
        throw EventKitHostLocatorError.missing
    }
}
#endif
