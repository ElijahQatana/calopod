import CalopodCommands
import CalopodDomain
import CalopodStore
import CryptoKit
import Foundation

/// One notification the app wants pending: what it says, when it fires, and what clicking it does.
struct PlannedReminder: Equatable, Sendable {
    let id: String
    let fireDate: Date
    let kind: NotificationSettings.Kind
    let title: String
    let body: String
    let eventID: String
    /// The meeting's web link, when the event has one. Join is only offered with it.
    let joinURL: String?

    var threadID: String { ReminderPlanner.threadPrefix + eventID }
    var category: String { joinURL == nil ? ReminderCategory.open : ReminderCategory.join }

    /// Changes whenever the time or the text does, so a pending notification that no longer matches is replaced.
    var fingerprint: String {
        let text = [String(Int(fireDate.timeIntervalSince1970)), title, body, joinURL ?? ""].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum ReminderCategory {
    static let join = "calopod.reminder.join"
    static let open = "calopod.reminder.open"
}

enum ReminderActionID {
    static let join = "calopod.reminder.action.join"
    static let open = "calopod.reminder.action.open"
}

/// Works out the reminders that should be pending. It reads nothing and posts nothing.
enum ReminderPlanner {
    static let idPrefix = "calopod.reminder."
    static let threadPrefix = "calopod.event."
    /// Only reminders that fire within a day are kept pending.
    static let horizon: TimeInterval = 24 * 3600
    static let limit = 128

    static func plan(
        schedule: CalendarSchedule?, settings: NotificationSettings, now: Date,
        ignored: (String) -> Bool, calendarName: (ScheduleCalendar) -> String,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> [PlannedReminder] {
        let leads = settings.leads
        guard let schedule, !leads.isEmpty else { return [] }
        let names = Dictionary(schedule.calendars.map { ($0.id, calendarName($0)) }, uniquingKeysWith: { first, _ in first })
        var planned: [PlannedReminder] = []
        for event in schedule.events where event.startsAt > now && UpNext.isCandidate(event, ignored: ignored) {
            let due = leads.compactMap { lead -> (NotificationSettings.Kind, Int, Date)? in
                let fire = event.startsAt.addingTimeInterval(-Double(lead.minutes) * 60)
                return fire > now && fire <= now.addingTimeInterval(horizon) ? (lead.kind, lead.minutes, fire) : nil
            }
            // If both land on the same moment the final one is the one shown.
            let kept = due.filter { entry in entry.0 == .final || !due.contains { $0.0 == .final && $0.2 == entry.2 } }
            for (kind, minutes, fire) in kept {
                planned.append(PlannedReminder(
                    id: id(for: event, kind: kind), fireDate: fire, kind: kind,
                    title: title(event, minutes: minutes, hide: settings.hideTitles),
                    body: body(event, calendar: names[event.calendarID], hide: settings.hideTitles, timeZone: timeZone, locale: locale),
                    eventID: event.id, joinURL: event.meeting?.webURL.absoluteString))
            }
        }
        return Array(planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
    }

    static func id(for event: ScheduleEvent, kind: NotificationSettings.Kind) -> String {
        "\(idPrefix)\(event.id).\(kind.rawValue).\(Int(event.startsAt.timeIntervalSince1970))"
    }

    static func minutesText(_ minutes: Int) -> String { minutes == 1 ? "1 minute" : "\(minutes) minutes" }

    static func title(_ event: ScheduleEvent, minutes: Int, hide: Bool) -> String {
        hide ? "Meeting starting in \(minutesText(minutes))" : "\(event.title), in \(minutesText(minutes))"
    }

    /// The start time and the calendar's shown name, then the location or Join. With titles hidden only
    /// the time is shown, so nothing about the event leaks onto the screen.
    static func body(_ event: ScheduleEvent, calendar: String?, hide: Bool, timeZone: TimeZone, locale: Locale) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        var parts = [event.startsAt.formatted(style)]
        if !hide, let calendar, !calendar.isEmpty { parts.append(calendar) }
        if !hide, let place = locationText(event.location) {
            parts.append(place)
        } else if event.meeting != nil {
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
}

/// What is pending now and what should be, compared. Nothing outside our own ids is touched.
struct PendingReminder: Equatable, Sendable {
    let id: String
    let fingerprint: String?
}

struct ReminderDiff: Equatable {
    var add: [PlannedReminder] = []
    var remove: [String] = []
    var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

enum ReminderReconciler {
    static func diff(desired: [PlannedReminder], pending: [PendingReminder]) -> ReminderDiff {
        let ours = pending.filter { $0.id.hasPrefix(ReminderPlanner.idPrefix) }
        let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let have = Dictionary(ours.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        var result = ReminderDiff()
        var queued = Set<String>()
        for item in desired where !queued.contains(item.id) {
            // A changed fingerprint is added again under the same id, which replaces the old one.
            if let existing = have[item.id], existing == item.fingerprint { continue }
            queued.insert(item.id)
            result.add.append(item)
        }
        result.remove = ours.map(\.id).filter { wanted[$0] == nil }.sorted()
        return result
    }
}
