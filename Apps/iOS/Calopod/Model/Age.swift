import Foundation

enum Age {
    /// Data older than this is called out, since the Mac normally publishes much more often.
    static let staleAfter: TimeInterval = 2 * 3600

    static func isStale(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) > staleAfter
    }

    /// "just now", "12m", "3h" or "2d", for use as "3h ago".
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    static func lastUpdated(_ date: Date, now: Date) -> String {
        let age = short(date, now: now)
        return age == "just now" ? "Updated from your Mac just now" : "Last updated from your Mac \(age) ago"
    }
}
