import AppKit
import EventKit

enum CalendarOpenResult: Equatable, Sendable {
    case opened
    /// The event is gone, or its calendar is no longer on this Mac.
    case notFound
}

/// Opens the Calendar app for an event Calopod can read but not answer.
protocol CalendarOpening: Sendable {
    func open(eventID: String, startsAt: Date) -> CalendarOpenResult
}

enum CalendarOpenText {
    static let notFound = "Calendar can't find this event. It may have been deleted, or its calendar is no longer on this Mac."
    static let help = "Opens the Calendar app at this day, where you can answer. Nothing is sent from Calopod, and the answer is read on the next sync."
}

/// Calendar has no link to a single event, so this checks the event still exists and opens its day.
struct SystemCalendarOpener: CalendarOpening {
    func open(eventID: String, startsAt: Date) -> CalendarOpenResult {
        // Without full access the lookup cannot tell, so the day is opened anyway.
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess,
           EKEventStore().event(withIdentifier: eventID) == nil {
            return .notFound
        }
        if let url = Self.url(for: startsAt), NSWorkspace.shared.open(url) { return .opened }
        // If the link is not handled, at least bring Calendar forward.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        return .opened
    }

    /// A calshow: link carries seconds since the 2001 reference date, here for the start of the day.
    static func url(for date: Date, calendar: Calendar = .current) -> URL? {
        let seconds = Int(calendar.startOfDay(for: date).timeIntervalSinceReferenceDate)
        return URL(string: "calshow:\(seconds)")
    }
}
