import CalopodDomain
import CalopodSnapshot
import CalopodStore
import CalopodSync
import Foundation

/// Turns the local copy into the records the iPhone reads. It uses the same Inbox query, calendar
/// choice and availability calculation as the app and the command line, then keeps only what the
/// phone shows.
enum IPhoneFeedBuilder {
    /// How many days of busy time are published, starting with today.
    static let availabilityDays = 14
    /// Long notes are cut, so one record stays well under CloudKit's size limit.
    static let notesLimit = 2_000

    static func records(
        repository: LocalStateRepository, now: Date = Date(), calendar: Calendar = .current
    ) throws -> [SnapshotPayload] {
        let cutoff = now.addingTimeInterval(-3600)
        let snapshot = try repository.inboxContextSnapshot()
        let result = InboxAttentionQuery.evaluate(snapshot, filter: InboxAttentionFilter(asOf: now), freshnessCutoff: cutoff)

        var records: [SnapshotPayload] = []
        for row in result.rows {
            records.append(try SnapshotPayload(inboxItem(row, in: snapshot), kind: .inboxItem, at: now))
        }
        for day in try availability(repository: repository, now: now, calendar: calendar) {
            records.append(try SnapshotPayload(day, kind: .availabilityDay, at: now))
        }
        for day in try calendarDays(snapshot, repository: repository, now: now, calendar: calendar) {
            records.append(try SnapshotPayload(day, kind: .calendarDay, at: now))
        }
        records.append(try SnapshotPayload(calendars(snapshot, repository: repository), kind: .calendars, at: now))
        records.append(try SnapshotPayload(reminderSettings(try repository.notificationSettings()), kind: .reminderSettings, at: now))
        records.append(try SnapshotPayload(try syncStatus(snapshot, repository: repository, cutoff: cutoff), kind: .syncStatus, at: now))
        return records
    }

    // MARK: Inbox

    static func inboxItem(_ row: InboxAttentionRow, in snapshot: InboxContextSnapshot) -> InboxItem {
        let event = row.item.event
        // A private event keeps its time but none of its words.
        let shown = !event.isPrivate
        let titles = Dictionary(
            snapshot.events.map { ($0.event.sourceKeyHash, $0.event) }, uniquingKeysWith: { first, _ in first })
        let conflicts = row.conflicts.compactMap { conflict -> ConflictingEvent? in
            let other = conflict.pair.first == event.sourceKeyHash ? conflict.pair.second : conflict.pair.first
            guard let other = titles[other] else { return nil }
            return ConflictingEvent(title: other.isPrivate ? nil : other.title, startsAt: other.startsAt, endsAt: other.endsAt)
        }
        return InboxItem(
            id: event.sourceKeyHash, reasons: row.reasons.map(reason), changeOrderUncertain: row.changeTiming == .uncertain,
            title: shown ? event.title : nil, startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier, sourceName: row.source.connectionLabel ?? row.source.provider,
            calendarID: event.calendarBindingID, response: event.currentUserResponse.state,
            organizerName: shown ? event.organizer.flatMap { $0.name ?? $0.emailAddress } : nil,
            attendees: summary(event.attendees), location: shown ? event.location : nil,
            notes: shown ? event.notes.map { String($0.prefix(notesLimit)) } : nil, url: shown ? event.url : nil, conflicts: conflicts)
    }

    private static func reason(_ reason: InboxAttentionReason) -> InboxReason {
        switch reason {
        case .needsResponse: .needsRSVP
        case .maybe: .maybe
        case .changedAfterResponse: .unreadChange
        case .conflict: .conflict
        }
    }

    private static func summary(_ attendees: [EventParticipant]) -> AttendeeSummary {
        func count(_ words: Set<String>) -> Int { attendees.filter { words.contains($0.status?.lowercased() ?? "") }.count }
        return AttendeeSummary(
            total: attendees.count, accepted: count(["accepted"]),
            tentative: count(["tentative", "tentativelyaccepted"]), declined: count(["declined"]))
    }

    // MARK: Availability

    private static func availability(repository: LocalStateRepository, now: Date, calendar: Calendar) throws -> [CalopodSnapshot.AvailabilityDay] {
        let sources = (try? selectedCalendarSources(connectionID: nil, calendarID: nil, repository: repository)) ?? []
        let first = calendar.startOfDay(for: now)
        guard !sources.isEmpty, let end = calendar.date(byAdding: .day, value: availabilityDays, to: first) else { return [] }
        let events = try repository.normalizedInstances(calendarBindingIDs: sources.map(\.calendar.id), from: first, through: end)
        let hours = try repository.workingHours()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        return (0..<availabilityDays).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: first),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let range = DateInterval(start: start, end: next)
            let result = AvailabilityCalculator.calculate(
                instances: events, from: start, through: next, workingHours: hours, timeZone: calendar.timeZone)
            let summary = CalopodSync.AvailabilityDay(result, day: range)
            func ranges(_ list: [AvailabilityInterval]) -> [BusyInterval] { list.map { BusyInterval(start: $0.start, end: $0.end) } }
            return CalopodSnapshot.AvailabilityDay(
                day: format.string(from: start), timeZoneIdentifier: calendar.timeZone.identifier,
                busy: ranges(result.busy), working: result.workingWindows?.first.map { BusyInterval(start: $0.start, end: $0.end) },
                free: ranges(result.free), overlaps: result.overlaps, status: status(summary.load),
                outside: result.outside.map { OutsideBlock(start: $0.start, end: $0.end, side: side($0.side)) })
        }
    }

    private static func side(_ side: OutsideSide) -> HoursSide {
        switch side {
        case .before: .before
        case .after: .after
        case .dayOff: .dayOff
        }
    }

    private static func status(_ load: AvailabilityLoad) -> AvailabilityStatus {
        switch load {
        case .mostlyFree: .mostlyFree
        case .tight: .tight
        case .overbooked: .overbooked
        case .dayOff: .dayOff
        }
    }

    // MARK: Events of the chosen calendars

    /// Events for the same days as the busy time. The snapshot already leaves out cancelled events and
    /// Calopod's own copies, and `calendars` leaves out ignored calendars, so an event is only as real
    /// as the Calendar screen shows it. Days without events get no record.
    static func calendarDays(
        _ snapshot: InboxContextSnapshot, repository: LocalStateRepository, now: Date, calendar: Calendar
    ) throws -> [CalendarDay] {
        let shown = Set(calendars(snapshot, repository: repository).calendars.map(\.id))
        let chosen = try repository.iPhoneCalendarIDs().intersection(shown)
        guard !chosen.isEmpty else { return [] }
        let events = snapshot.events.filter { $0.isPresenceConfirmed && chosen.contains($0.event.calendarBindingID) }.map(\.event)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        let first = calendar.startOfDay(for: now)
        return (0..<availabilityDays).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: first),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let today = events.filter { $0.endsAt > start && $0.startsAt < next }.map { calendarEvent($0, now: now) }
            return today.isEmpty ? nil : CalendarDay(
                day: format.string(from: start), timeZoneIdentifier: calendar.timeZone.identifier, events: today)
        }
    }

    private static func calendarEvent(_ event: StoredNormalizedInstance, now: Date) -> CalendarEvent {
        // A private event keeps its time but none of its words, and its link.
        let shown = !event.isPrivate
        let remindable = ReminderEligibility.isEligible(isAllDay: event.isAllDay, isDeclined: event.currentUserResponse.state == .declined)
        return CalendarEvent(
            id: event.sourceKeyHash, calendarID: event.calendarBindingID, title: shown ? event.title : nil,
            startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
            location: shown ? event.location : nil, response: event.currentUserResponse.state,
            joinURL: shown && remindable && event.endsAt > now ? JoinSelector.link(for: event)?.webURL.absoluteString : nil)
    }

    static func reminderSettings(_ settings: NotificationSettings) -> ReminderSettings {
        ReminderSettings(
            enabled: settings.enabled, firstEnabled: settings.firstEnabled, firstMinutes: settings.firstMinutes,
            finalEnabled: settings.finalEnabled, finalMinutes: settings.finalMinutes, hideTitles: settings.hideTitles)
    }

    // MARK: Calendars and status

    static func calendars(_ snapshot: InboxContextSnapshot, repository: LocalStateRepository) -> CalendarList {
        let names = CalendarNames(repository)
        let palette = CalendarPalette.entries.map(\.id)
        let gray = palette.firstIndex(of: "gray") ?? 0
        return CalendarList(calendars: snapshot.sources.filter { !names.isIgnored($0.bindingID) }.map { source in
            CalendarEntry(
                id: source.bindingID,
                name: names.shown(source.bindingID, real: source.calendarLabel) ?? source.connectionLabel ?? "Calendar",
                colorIndex: names.preferences[source.bindingID]?.color.flatMap(palette.firstIndex(of:)) ?? gray)
        })
    }

    private static func syncStatus(
        _ snapshot: InboxContextSnapshot, repository: LocalStateRepository, cutoff: Date
    ) throws -> SyncStatus {
        var issues: [SyncIssue] = []
        for source in snapshot.sources {
            if let since = source.staleSince {
                issues.append(SyncIssue(kind: .stale, calendarID: source.bindingID, since: since))
            } else if let health = source.healthStatus, health != "healthy" {
                issues.append(SyncIssue(kind: .failed, calendarID: source.bindingID))
            } else if source.coverage.map({ $0.observedAt < cutoff }) ?? true {
                issues.append(SyncIssue(kind: .partial, calendarID: source.bindingID))
            }
        }
        if let latest = try repository.latestSyncRun(), ["failed", "interrupted"].contains(latest.status) {
            issues.append(SyncIssue(kind: .failed, since: latest.finishedAt ?? latest.startedAt))
        }
        return SyncStatus(lastSyncAt: try repository.latestSuccessfulSyncRun()?.finishedAt, issues: issues)
    }
}
