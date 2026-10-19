import AppKit
import EventKit

enum CalendarOpenResult: Equatable, Sendable {
    case opened
    /// The event is gone, or its calendar is no longer on this Mac.
    case notFound
    /// The Calendar app could not be started.
    case unavailable
}

/// Opens the Calendar app for an event Calopod can read but not answer.
protocol CalendarOpening: Sendable {
    func open(eventID: String, startsAt: Date) -> CalendarOpenResult
}

enum CalendarOpenText {
    static let notFound = "Calendar can't find this event. It may have been deleted, or its calendar is no longer on this Mac."
    static let unavailable = "The Calendar app could not be opened."
    static let help = "Opens the Calendar app, where you can answer. Nothing is sent from Calopod, and the answer is read on the next sync."

    /// Calendar cannot be sent to one event from here, so the message says where to look.
    static func hint(title: String, startsAt: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        style.locale = calendar.locale ?? .current
        return "Calendar is open. Look for “\(title)” on \(startsAt.formatted(style))."
    }

    static func message(for result: CalendarOpenResult, title: String, startsAt: Date) -> String? {
        switch result {
        case .opened: hint(title: title, startsAt: startsAt)
        case .notFound: notFound
        case .unavailable: unavailable
        }
    }
}

/// macOS has no link to one event, so this checks the event still exists and brings Calendar forward.
struct SystemCalendarOpener: CalendarOpening {
    func open(eventID: String, startsAt: Date) -> CalendarOpenResult {
        // Without full access the lookup cannot tell, so Calendar is opened anyway.
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess,
           EKEventStore().event(withIdentifier: eventID) == nil {
            return .notFound
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            return .unavailable
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return .opened
    }

    static let bundleID = "com.apple.iCal"
}
