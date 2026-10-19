import CalopodSnapshot
import Foundation

/// What the Settings and About screens say about iCloud, taken from how the last read went.
struct SettingsInfo: Equatable {
    enum ICloud: Equatable { case signedIn, signedOut, unreachable }

    var icloud: ICloud
    /// When the Mac last published, if the phone has anything from it.
    var lastUpdate: Date?
    var reminders: ReminderSettings?

    init(phase: SnapshotStore.Phase) {
        switch phase {
        case .content(let snapshot, _):
            icloud = .signedIn
            lastUpdate = snapshot.publishedAt
            reminders = snapshot.reminders
        case .signedOut: icloud = .signedOut
        case .failed: icloud = .unreachable
        default: icloud = .signedIn
        }
    }

    /// "10 min before", "10 min and 1 min before" or "Off", for the lead times the Mac chose.
    var leadTimes: String {
        guard let reminders else { return "Not shared yet" }
        guard !reminders.leadMinutes.isEmpty else { return "Off" }
        return reminders.leadMinutes.map { "\($0) min" }.formatted(.list(type: .and)) + " before"
    }

    var titles: String {
        guard let reminders else { return "Not shared yet" }
        return reminders.hideTitles ? "Hidden" : "Shown"
    }
}

enum AppInfo {
    /// "1.0 (42)", from the app's bundle.
    static func version(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}
