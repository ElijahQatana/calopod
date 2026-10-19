import CalopodEventKit
import CalopodProviders
import Foundation

/// What to tell someone whose Calendar helper cannot read calendars: which helper was asked, what
/// macOS calls it in Privacy settings, and the one fix for the case at hand. The command line
/// errors, `calopod doctor` and the app's Calendar access card all use this wording.
public struct CalendarAccessGuidance: Equatable, Sendable {
    /// The helper app, with the home folder shown as `~`.
    public let helperPath: String
    public let accessStatus: String
    public let fix: String
    public let message: String

    /// What macOS lists in Calendar privacy settings for a helper inside Calopod.app.
    public static let appIdentity = "Calopod"
    /// What it lists for a standalone helper.
    public static let standaloneIdentity = "Calopod EventKit Host"

    public init(helperPath: String, status: EventKitAccessStatus, home: String = NSHomeDirectory()) {
        let shown = Self.display(helperPath, home: home)
        let parts = helperPath.split(separator: "/").map(String.init)
        let insideApp = parts.dropLast().contains { $0.hasSuffix(".app") }
        let buildCopy = parts.dropLast().contains(".build")
        let identity = insideApp ? Self.appIdentity : Self.standaloneIdentity

        let opening: String
        var fix: String
        switch status {
        case .notDetermined:
            opening = "Calopod cannot read your calendars yet. macOS has not asked about the helper at \(shown)."
            let command = "open -W -n --stdout /tmp/h.json --stderr /tmp/h.err \"\(Self.shellPath(helperPath, home: home))\" --args --request-permission"
            fix = "To ask once, run: \(command)"
            if insideApp { fix += " Or in the Calopod app, choose Settings, Permissions, Allow." }
        case .restricted:
            opening = "Calopod cannot read your calendars. A profile or Screen Time limit restricts Calendar access for the helper at \(shown)."
            fix = Self.turnOn
        case .writeOnly:
            opening = "Calopod cannot read your calendars. The helper at \(shown) only has write access to Calendar."
            fix = Self.turnOn
        case .denied, .unknown, .fullAccess:
            opening = "Calopod cannot read your calendars. Calendar access is off for the helper at \(shown)."
            fix = Self.turnOn
        }
        if buildCopy {
            fix += " This helper is a build copy. The installed command in ~/.local/bin may use a different helper that is already allowed."
        }

        self.helperPath = shown
        self.accessStatus = status.rawValue
        self.fix = fix
        self.message = "\(opening) macOS lists it as \"\(identity)\" in Privacy & Security, Calendars. \(fix)"
    }

    private static let turnOn =
        "Turn it on with Full Access in System Settings, Privacy & Security, Calendars. To open that page, run: open \"\(Permissions.calendarPrivacyURL)\""

    /// `~` for the home folder, as `calopod doctor` prints helper paths.
    static func display(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The path for a double-quoted shell word. `~` does not expand there, so `$HOME` stands in.
    private static func shellPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/", path.hasPrefix(home + "/") else { return path }
        return "$HOME" + path.dropFirst(home.count)
    }
}

/// Thrown when the Calendar helper answered but may not read calendars, so the error can say
/// which helper and what to do.
struct CalendarAccessDeniedError: Error, Equatable {
    let guidance: CalendarAccessGuidance

    /// The error for a helper reply that was not full access. A full-access reply with an error
    /// code is some other failure, so it keeps the general permission error.
    static func make(helper: URL, status: EventKitAccessStatus) -> Error {
        status == .fullAccess
            ? ProviderFailure.permissionDenied
            : CalendarAccessDeniedError(guidance: CalendarAccessGuidance(helperPath: helper.path, status: status))
    }
}
