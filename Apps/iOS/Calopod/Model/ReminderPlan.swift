import CalopodSnapshot
import Foundation

/// One local notification the phone wants pending.
struct PlannedReminder: Equatable, Sendable {
    let id: String
    let fireDate: Date
    let title: String
    let body: String
    let eventID: String
    /// The meeting's web link. Join is only offered with it.
    let joinURL: URL?

    var category: String { joinURL == nil ? ReminderPlan.openCategory : ReminderPlan.joinCategory }
}

/// Works out which reminders should be pending from the Mac's last snapshot, the way the Mac does from
/// its own schedule: the lead times and the hidden titles come from the Mac's settings. It reads nothing
/// and posts nothing.
enum ReminderPlan {
    static let idPrefix = "calopod.reminder."
    static let joinCategory = "calopod.reminder.join"
    static let openCategory = "calopod.reminder.open"
    /// Only reminders that fire within a day are kept pending.
    static let horizon: TimeInterval = 24 * 3600
    /// iOS keeps at most 64 pending local notifications, so stay under it.
    static let limit = 60

    static func plan(
        snapshot: Snapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> [PlannedReminder] {
        guard let settings = snapshot.reminders else { return [] }
        let leads = settings.leadMinutes
        guard !leads.isEmpty else { return [] }
        let names = Dictionary(snapshot.calendars.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // An event that runs past midnight is listed on each day it touches.
        var seen = Set<String>()
        let events = snapshot.days.flatMap(\.events).filter { seen.insert($0.id).inserted }
        var planned: [PlannedReminder] = []
        for event in events where event.startsAt > now
            && ReminderEligibility.isEligible(isAllDay: event.isAllDay, isDeclined: event.response == .declined) {
            for minutes in Set(leads) {
                let fire = event.startsAt.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now, fire <= now.addingTimeInterval(horizon) else { continue }
                planned.append(PlannedReminder(
                    id: "\(idPrefix)\(event.id).\(minutes).\(Int(event.startsAt.timeIntervalSince1970))", fireDate: fire,
                    title: title(event, minutes: minutes, hide: settings.hideTitles),
                    body: body(event, calendar: names[event.calendarID], hide: settings.hideTitles, timeZone: timeZone, locale: locale),
                    eventID: event.id, joinURL: event.joinURL.flatMap(webLink)))
            }
        }
        return Array(planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
    }

    static func minutesText(_ minutes: Int) -> String { minutes == 1 ? "1 minute" : "\(minutes) minutes" }

    static func title(_ event: CalendarEvent, minutes: Int, hide: Bool) -> String {
        hide ? "Meeting starting in \(minutesText(minutes))" : "\(event.title ?? "Busy"), in \(minutesText(minutes))"
    }

    /// The start time and the calendar's name, then the location or Join. With titles hidden only the
    /// time is shown, so nothing about the event shows on the lock screen.
    static func body(_ event: CalendarEvent, calendar: String?, hide: Bool, timeZone: TimeZone, locale: Locale) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        var parts = [event.startsAt.formatted(style)]
        if !hide, let calendar, !calendar.isEmpty { parts.append(calendar) }
        if !hide, let place = locationText(event.location) {
            parts.append(place)
        } else if event.joinURL.flatMap(webLink) != nil {
            parts.append("Join")
        }
        return parts.joined(separator: " · ")
    }

    /// A short single line, and nothing that is just a web address.
    static func locationText(_ location: String?) -> String? {
        let line = location?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty, !line.contains("://") else { return nil }
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// Only https links are offered, so a stored link can't open anything else.
    static func webLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

extension ReminderPlan {
    /// What the Mac has chosen, in a sentence for the Status screen.
    static func summary(_ settings: ReminderSettings?) -> String {
        guard let settings else { return "Your Mac hasn't shared its reminder settings yet. Update Calopod on your Mac." }
        let leads = settings.leadMinutes
        guard settings.enabled else { return "Reminders are off on your Mac, so none are set here." }
        guard !leads.isEmpty else { return "Both reminders are off on your Mac, so none are set here." }
        let times = leads.map { minutesText($0) }.formatted(.list(type: .and))
        return "Set on your Mac: \(times) before a meeting, with titles \(settings.hideTitles ? "hidden" : "shown")."
    }
}
