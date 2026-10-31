import Foundation

/// What an Arm may put on its target. `busy` is timing only; `label` is timing under the Arm's
/// fixed label; `fullDetails` (Main calendar) adds title, location and notes.
public enum ArmRuleMode: String, CaseIterable, Codable, Sendable {
    case busy
    case label
    case fullDetails = "full-details"
}

/// Events an Arm leaves out. All off copies everything.
public struct ArmFilters: Equatable, Codable, Sendable {
    public var skipDeclined: Bool
    public var skipAllDay: Bool
    public var skipDontClone: Bool

    public init(skipDeclined: Bool = false, skipAllDay: Bool = false, skipDontClone: Bool = false) {
        self.skipDeclined = skipDeclined
        self.skipAllDay = skipAllDay
        self.skipDontClone = skipDontClone
    }

    public var isEmpty: Bool { self == ArmFilters() }
}

/// Time a copy covers before and after its event, in minutes. All-day events are never padded.
public struct ArmPadding: Equatable, Codable, Sendable {
    public static let maxMinutes = 480

    public var beforeMinutes: Int
    public var afterMinutes: Int
    /// Pad only events with a location and no meeting link.
    public var inPersonOnly: Bool

    public init(beforeMinutes: Int = 0, afterMinutes: Int = 0, inPersonOnly: Bool = false) {
        self.beforeMinutes = beforeMinutes
        self.afterMinutes = afterMinutes
        self.inPersonOnly = inPersonOnly
    }

    public var isEmpty: Bool { beforeMinutes == 0 && afterMinutes == 0 }

    /// Minutes are elapsed time, so a clock change inside the padding does not shift it.
    public func padded(
        startsAt: Date, endsAt: Date, isAllDay: Bool, location: String?, url: String?, notes: String?
    ) -> (startsAt: Date, endsAt: Date) {
        guard !isEmpty, !isAllDay, !inPersonOnly || isInPerson(location: location, url: url, notes: notes) else {
            return (startsAt, endsAt)
        }
        return (startsAt.addingTimeInterval(-Double(beforeMinutes) * 60),
                endsAt.addingTimeInterval(Double(afterMinutes) * 60))
    }

    private func isInPerson(location: String?, url: String?, notes: String?) -> Bool {
        guard location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        return MeetingLink.find(url: url, location: location, notes: notes) == nil
    }
}
