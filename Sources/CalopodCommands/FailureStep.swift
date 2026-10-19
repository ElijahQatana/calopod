import Foundation

/// Plain words for the step a sync run stopped at, shared by the command line and the Mac app.
public enum FailureStep {
    public static func description(for category: String) -> String {
        switch category {
        case "source-refresh": "could not read the source calendars"
        case "target-refresh": "could not read the target calendars"
        case "permission": "Calendar access is off for Calopod"
        case "eventkit-host", "eventkit-host-response": "the Calendar helper did not answer correctly"
        case "eventkit-host-timeout": "the Calendar helper took too long to answer"
        case "authorization", "account-policy", "consent", "credential-access": "a calendar account needs to be reconnected"
        case "local-state": "Calopod's saved data could not be used"
        case "busy": "another sync was already running"
        case "interrupted": "the run was cut off before it finished"
        case "convergence": "the copies did not settle after writing"
        case "configuration", "writer-policy": "the enabled Connections and Arms need review"
        default: "a calendar provider did not answer"
        }
    }

    /// "4 minutes", "3 hours", for a count of seconds.
    public static func ago(_ seconds: Int) -> String {
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        switch seconds {
        case ..<120: return unit(seconds, "second")
        case ..<7200: return unit(seconds / 60, "minute")
        case ..<172_800: return unit(seconds / 3600, "hour")
        default: return unit(seconds / 86_400, "day")
        }
    }
}
