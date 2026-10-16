import Foundation

/// Public OAuth client IDs and the EventKit host location, which the shared services read from
/// the process environment. A Finder-launched app has no shell exports, so they come from the
/// app's Info.plist (written by the build script) instead.
enum AppConfiguration {
    private static let plistKeys: [(plist: String, variable: String)] = [
        ("CalopodGoogleClientID", "CALOPOD_GOOGLE_CLIENT_ID"),
        ("CalopodMicrosoftClientID", "CALOPOD_MICROSOFT_CLIENT_ID"),
        ("CalopodMicrosoftTenant", "CALOPOD_MICROSOFT_TENANT"),
    ]

    static func apply() {
        let environment = ProcessInfo.processInfo.environment
        for key in plistKeys where (environment[key.variable] ?? "").isEmpty {
            if let value = Bundle.main.object(forInfoDictionaryKey: key.plist) as? String,
               !value.isEmpty {
                setenv(key.variable, value, 1)
            }
        }
        // Development fallback: a source-installed EventKit host sits in the one location where an
        // ad-hoc signature is trusted. A team-signed bundled host needs none of this.
        if (environment["CALOPOD_EVENTKIT_HOST_APP"] ?? "").isEmpty {
            let installed = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Calopod/Service/eventkit-host/Calopod EventKit Host.app",
                    isDirectory: true
                )
            if FileManager.default.fileExists(atPath: installed.path) {
                setenv("CALOPOD_EVENTKIT_HOST_APP", installed.path, 1)
            }
        }
    }
}
