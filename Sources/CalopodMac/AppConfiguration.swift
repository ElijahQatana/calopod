import CalopodEventKit
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
        if let host = devHost(environment: environment) {
            setenv("CALOPOD_EVENTKIT_HOST_APP", host.path, 1)
        }
    }

    /// A development build is ad hoc signed, so its own helper is not trusted and the source-install
    /// helper stands in. A helper inside the app that passes the signature check always wins.
    static func devHost(
        environment: [String: String],
        executableURL: URL? = Bundle.main.executableURL,
        installed: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Calopod/Service/eventkit-host/\(EventKitHostLocator.appName)",
            isDirectory: true
        ),
        verify: (URL) throws -> Void = EventKitHostSignature.verify(appURL:)
    ) -> URL? {
        guard (environment["CALOPOD_EVENTKIT_HOST_APP"] ?? "").isEmpty,
              FileManager.default.fileExists(atPath: installed.path) else { return nil }
        if let executableURL,
           let bundled = try? EventKitHostLocator.resolve(variables: [:], executableURL: executableURL),
           (try? verify(bundled)) != nil {
            return nil
        }
        return installed
    }
}
