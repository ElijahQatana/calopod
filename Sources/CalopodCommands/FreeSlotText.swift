import CalopodSync
import Foundation

/// Free windows as plain lines to paste into a message: times and the zone, nothing else.
public enum FreeSlotText {
    public static func text(_ windows: [AvailabilityInterval], timeZone: TimeZone) -> String {
        windows.map { line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    private static func line(_ window: AvailabilityInterval, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = format("EEE MMM d", timeZone)
        let clock = format("h:mm a", timeZone)
        let startZone = zone(window.start, timeZone), endZone = zone(window.end, timeZone)

        // An end at midnight belongs to the day that is ending.
        let sameDay = calendar.isDate(window.start, inSameDayAs: window.end.addingTimeInterval(-1))
        let meridiem = format("a", timeZone)
        let start = clock.string(from: window.start), end = clock.string(from: window.end)
        let sameHalf = meridiem.string(from: window.start) == meridiem.string(from: window.end)

        var text = "\(day.string(from: window.start)), "
        if sameDay, sameHalf, startZone == endZone {
            text += "\(start.dropLast(3)) to \(end)"
        } else {
            text += startZone == endZone ? start : "\(start) \(startZone)"
            text += " to " + (sameDay ? "" : "\(day.string(from: window.end.addingTimeInterval(-1))), ") + end
        }
        return "\(text) \(endZone)"
    }

    private static func zone(_ date: Date, _ timeZone: TimeZone) -> String {
        timeZone.abbreviation(for: date) ?? timeZone.identifier
    }

    private static func format(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
