import Foundation

/// A Finder-launched app has no shell exports, so the OAuth client IDs come from Info.plist.
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
        // Dev builds: ad-hoc signed hosts are only trusted in the source-install location.
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
