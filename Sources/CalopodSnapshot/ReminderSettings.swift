import Foundation

/// The Mac's meeting reminder choices, so the phone reminds at the same times. It has no event data.
public struct ReminderSettings: SnapshotRecord {
    public static let recordID = "reminder-settings"

    public let enabled: Bool
    public let firstEnabled: Bool
    public let firstMinutes: Int
    public let finalEnabled: Bool
    public let finalMinutes: Int
    public let hideTitles: Bool

    public var id: String { Self.recordID }

    public init(
        enabled: Bool, firstEnabled: Bool, firstMinutes: Int, finalEnabled: Bool, finalMinutes: Int, hideTitles: Bool
    ) {
        self.enabled = enabled
        self.firstEnabled = firstEnabled
        self.firstMinutes = firstMinutes
        self.finalEnabled = finalEnabled
        self.finalMinutes = finalMinutes
        self.hideTitles = hideTitles
    }

    /// The minutes before the start of each reminder that is on. Empty when reminders are off.
    public var leadMinutes: [Int] {
        guard enabled else { return [] }
        return (firstEnabled ? [firstMinutes] : []) + (finalEnabled ? [finalMinutes] : [])
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, firstEnabled, firstMinutes, finalEnabled, finalMinutes, hideTitles
    }
}

/// Which events get a reminder, apart from the calendars chosen and events Calopod copied, which the Mac
/// and the feed already leave out. The Mac's Next card and the feed both ask here.
public enum ReminderEligibility {
    public static func isEligible(isAllDay: Bool, isDeclined: Bool) -> Bool { !isAllDay && !isDeclined }
}
