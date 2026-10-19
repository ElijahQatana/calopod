import CalopodSnapshot
import Foundation

/// The words and links for one event page, worked out once so the view only lays them out.
struct EventDetail: Equatable {
    var item: InboxItem
    var untitled = "Untitled"

    var title: String { item.title ?? untitled }

    var response: String {
        switch item.response {
        case .needsResponse: "Not answered yet"
        case .accepted: "Yes"
        case .tentative: "Maybe"
        case .declined: "No"
        case .organizer: "You organize this"
        case .notApplicable: "No answer needed"
        case .unknown: "Unknown"
        }
    }

    /// "9 invited · 5 yes · 1 maybe · 1 no", or nil when it is only you.
    var guests: String? {
        let a = item.attendees
        guard a.total > 0 else { return nil }
        let parts = [("yes", a.accepted), ("maybe", a.tentative), ("no", a.declined)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        return (["\(a.total) invited"] + parts).joined(separator: " · ")
    }

    var location: String? { Self.text(item.location) }
    var notes: String? { Self.text(item.notes) }
    var organizer: String? { Self.text(item.organizerName) }
    var source: String? { Self.text(item.sourceName) }

    /// Only web links are offered, so a stored link can't open anything else.
    var link: URL? {
        guard let text = Self.text(item.url), let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }

    private static func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension InboxItem {
    /// A calendar event for the detail page. It carries only what the Mac publishes for events:
    /// no notes, people or link.
    init(_ event: CalendarEvent) {
        self.init(
            id: event.id, reasons: [], title: event.title, startsAt: event.startsAt, endsAt: event.endsAt,
            isAllDay: event.isAllDay, calendarID: event.calendarID, response: event.response, location: event.location)
    }
}
