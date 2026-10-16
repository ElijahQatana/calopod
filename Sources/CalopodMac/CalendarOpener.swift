import AppKit

/// Opens the Calendar app at an event's day. Used for events Calopod can read but not answer.
struct CalendarOpener: Sendable {
    var open: @Sendable (Date) -> Void

    static let system = CalendarOpener { day in
        if let url = url(for: day), NSWorkspace.shared.open(url) { return }
        // If the link is not handled, at least bring Calendar forward.
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A calshow: link carries seconds since the 2001 reference date, here for the start of the day.
    static func url(for date: Date, calendar: Calendar = .current) -> URL? {
        let seconds = Int(calendar.startOfDay(for: date).timeIntervalSinceReferenceDate)
        return URL(string: "calshow:\(seconds)")
    }
}
