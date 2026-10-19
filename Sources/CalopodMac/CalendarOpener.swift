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

/// Calendar handles `ical://ekevent/<id>` and selects that exact event, so the id is the only thing
/// that picks it. Nothing is matched by title, time or calendar, which could land on a Busy copy.
enum CalendarEventLink {
    static func url(eventID: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard !eventID.isEmpty, let path = eventID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ical://ekevent/\(path)?method=show&options=more")
    }
}

/// Checks the event still exists, then asks Calendar to show it.
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
        let configuration = NSWorkspace.OpenConfiguration()
        if let link = CalendarEventLink.url(eventID: eventID) {
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
        return .opened
    }

    static let bundleID = "com.apple.iCal"
}
