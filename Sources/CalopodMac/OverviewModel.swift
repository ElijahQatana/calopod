import CalopodCommands
import Foundation

/// The small decisions the Overview screen makes about its own layout and wording.
enum OverviewLayout {
    /// Below this window width the right column goes under the left one.
    static let wideWindow: CGFloat = 900

    /// `contentWidth` is the room inside the page margins. The window is that plus the margins,
    /// the sidebar (open or the icon rail) and the gaps around the panels.
    static func isWide(contentWidth: CGFloat, sidebarCollapsed: Bool) -> Bool {
        let sidebar = sidebarCollapsed ? Sidebar.railWidth : Sidebar.width
        return contentWidth + Theme.pagePadding * 2 + sidebar + Sidebar.inset * 3 >= wideWindow
    }

    /// The right column takes about two fifths of the room, within these limits.
    static func sideWidth(contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 0.38, 270), 440)
    }
}

/// How fresh one calendar's local copy is, in a few words.
struct CalendarFreshnessLabel: Equatable {
    let text: String
    /// True when events may be missing, so the label is shown as a warning.
    let isBehind: Bool

    static func make(
        _ calendar: ScheduleCalendar, range: Range<Date>, now: Date, timeZone: TimeZone = .current
    ) -> CalendarFreshnessLabel {
        switch calendar.freshness {
        case .unread: return CalendarFreshnessLabel(text: "Not read yet", isBehind: true)
        case .stale: return CalendarFreshnessLabel(text: "Out of date", isBehind: true)
        case .current:
            if let coverage = calendar.coverage,
               CoverageGap.describe(read: coverage, range: range, timeZone: timeZone) != nil {
                return CalendarFreshnessLabel(text: "Partly read", isBehind: true)
            }
            guard let readAt = calendar.readAt else { return CalendarFreshnessLabel(text: "Up to date", isBehind: false) }
            let age = max(0, Int(now.timeIntervalSince(readAt)))
            return CalendarFreshnessLabel(text: "Updated \(Format.ago(age))", isBehind: false)
        }
    }
}

/// The small tags beside an event in Next up today.
enum UpNextTag: Equatable {
    case soon(minutes: Int)
    case overlaps

    /// "In 40 min" only for the event that is next, and only when it starts within the hour.
    static func tags(for event: ScheduleEvent, isNext: Bool, now: Date) -> [UpNextTag] {
        var tags: [UpNextTag] = []
        let minutes = Int((event.startsAt.timeIntervalSince(now) / 60).rounded(.up))
        if isNext, (1...60).contains(minutes) { tags.append(.soon(minutes: minutes)) }
        if ScheduleLayout.showsOverlap(event) { tags.append(.overlaps) }
        return tags
    }

    var text: String {
        switch self {
        case .soon(let minutes): "In \(minutes) min"
        case .overlaps: "Overlaps"
        }
    }
}

enum EventDuration {
    /// "15 min", "1 hr", "1 hr 30 min".
    static func text(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    /// Like `text`, but says "0 min" for no time at all.
    static func total(_ seconds: TimeInterval) -> String { seconds < 30 ? "0 min" : text(seconds) }
}
