#if os(macOS)
import CalopodDomain
import CalopodSnapshot
import CalopodStore
import CalopodSync
import Foundation
import Testing

@testable import CalopodCommands

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func event(
    _ key: String, hour: Double, isPrivate: Bool, url: String? = nil, state response: EventResponseState = .needsResponse,
    isAllDay: Bool = false, hours: Double = 1
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: key, connectionID: "c", calendarBindingID: "cal", providerEventID: key, recurrenceID: nil,
        startsAt: now.addingTimeInterval(hour * 3600), endsAt: now.addingTimeInterval((hour + hours) * 3600),
        isAllDay: isAllDay, availability: "busy", isCancelled: false, isPrivate: isPrivate, title: "Title \(key)",
        contentFingerprint: key, providerUpdatedAt: nil, location: "Room 4", notes: String(repeating: "n", count: 5_000), url: url,
        attendees: [EventParticipant(emailAddress: "a@example.com", status: "accepted"), EventParticipant(status: "declined")],
        currentUserResponse: EventResponse(
            state: response, evidence: .googleSelf,
            actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
}

private func fixture(extra: [StoredNormalizedInstance] = []) throws -> LocalStateRepository {
    let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
    try state.saveConnection(StoredConnection(
        id: "c", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
    try state.replaceCalendarBindings(connectionID: "c", bindings: [
        StoredCalendarBinding(
            id: "cal", connectionID: "c", providerCalendarID: "cal", displayLabel: "Work",
            isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
    ])
    try state.applyEventRefresh(
        connectionID: "c", calendarBindingID: "cal", windowStart: now.addingTimeInterval(-86_400),
        windowEnd: now.addingTimeInterval(7 * 86_400),
        instances: [event("a", hour: 2, isPrivate: false), event("b", hour: 2.5, isPrivate: true)] + extra,
        cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    return state
}

private func finishSync(_ state: LocalStateRepository, id: String) throws {
    try state.beginSyncRun(mode: "apply", trigger: "automatic", id: id, now: now)
    try state.finishSyncRun(id: id, status: "succeeded", now: now)
}

private func service(_ state: LocalStateRepository, at date: Date = now) -> IPhoneFeedService {
    IPhoneFeedService(makeRepository: { state }, now: { date })
}

private func zoned(_ day: Int, _ hour: Double) -> Date {
    // March 2027 in New York: the clocks go forward on the 14th.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let start = calendar.date(from: DateComponents(year: 2027, month: 3, day: day))!
    return calendar.date(bySettingHour: Int(hour), minute: Int(hour * 60) % 60, second: 0, of: start)!
}

@Suite("iPhone feed")
struct IPhoneFeedTests {
    @Test("The records carry what the phone shows, and a private event keeps only its time")
    func buildsRecords() throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let records = try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian))
        let kinds = Dictionary(grouping: records, by: \.kind).mapValues(\.count)
        #expect(kinds[.inboxItem] == 2 && kinds[.availabilityDay] == IPhoneFeedBuilder.availabilityDays)
        #expect(kinds[.calendars] == 1 && kinds[.syncStatus] == 1)

        func item(_ key: String) throws -> InboxItem {
            let payload = try #require(records.first { $0.recordName == key })
            return try SnapshotCoding.decode(InboxItem.self, from: payload.bytes).record
        }
        let open = try item("a"), hidden = try item("b")
        #expect(open.title == "Title a" && open.location == "Room 4" && open.notes?.count == IPhoneFeedBuilder.notesLimit)
        #expect(open.reasons.contains(.needsRSVP) && open.reasons.contains(.conflict))
        #expect(open.attendees == AttendeeSummary(total: 2, accepted: 1, declined: 1))
        #expect(open.conflicts.first?.title == nil)
        #expect(hidden.title == nil && hidden.location == nil && hidden.notes == nil && hidden.organizerName == nil)
        #expect(open.conflicts.map(\.startsAt) == [hidden.startsAt])

        let list = try #require(records.first { $0.kind == .calendars })
        #expect(try SnapshotCoding.decode(CalendarList.self, from: list.bytes).record.calendars
            == [CalendarEntry(id: "cal", name: "Work", colorIndex: 11, color: "gray")])
        let status = try #require(records.first { $0.kind == .syncStatus })
        #expect(try SnapshotCoding.decode(SyncStatus.self, from: status.bytes).record.lastSyncAt == now)
    }

    @Test("Status carries the latest 24 runs, oldest first, failures included")
    func statusHistory() throws {
        let state = try fixture()
        for index in 0..<30 {
            let id = "run\(index)", at = now.addingTimeInterval(Double(index - 40) * 300)
            try state.beginSyncRun(mode: "apply", trigger: "automatic", id: id, now: at)
            try state.finishSyncRun(id: id, status: index == 5 || index == 29 ? "failed" : "succeeded", now: at)
        }
        let records = try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian))
        let payload = try #require(records.first { $0.kind == .syncStatus })
        let status = try SnapshotCoding.decode(SyncStatus.self, from: payload.bytes).record
        let runs = try #require(status.runs)
        #expect(runs.count == IPhoneFeedBuilder.runsLimit && runs.map(\.at) == runs.map(\.at).sorted())
        #expect(runs.indices.filter { runs[$0].failed } == [23])
        #expect(status.calendarUpdates?.map(\.calendarID) == ["cal"])
    }

    @Test("Nothing is sent until it is turned on, then once per sync")
    func publishesAfterEachSync() async throws {
        let state = try fixture()
        let feed = service(state), remote = InMemorySnapshotPublisher()
        try finishSync(state, id: "run1")
        #expect(await feed.run(publisher: remote) == .idle)
        #expect(await remote.replaceCount == 0)

        try feed.setEnabled(true)
        guard case .published(let count) = await feed.run(publisher: remote) else { Issue.record("not published"); return }
        let stored = await remote.records.count
        #expect(count == 2 + IPhoneFeedBuilder.availabilityDays + 3 && stored == count)
        #expect(await feed.run(publisher: remote) == .idle)

        try finishSync(state, id: "run2")
        guard case .published = await feed.run(publisher: remote) else { Issue.record("not published"); return }
        #expect(await remote.replaceCount == 2)
        #expect(try feed.state().publishedRunID == "run2")
    }

    @Test("A failed upload is recorded, retried later, and never thrown")
    func failureIsShownAndRetried() async throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let remote = InMemorySnapshotPublisher()
        await remote.setFailing(true)
        try service(state).setEnabled(true)
        guard case .failed = await service(state).run(publisher: remote) else { Issue.record("did not fail"); return }
        let failed = try service(state).state()
        #expect(failed.failure != nil && failed.failedAt == now && failed.publishedAt == nil)

        await remote.setFailing(false)
        #expect(await service(state, at: now.addingTimeInterval(60)).run(publisher: remote) == .idle)
        let later = now.addingTimeInterval(IPhoneFeedService.retryDelay + 1)
        guard case .published = await service(state, at: later).run(publisher: remote) else { Issue.record("not retried"); return }
        #expect(try service(state).state().failure == nil)
    }

    @Test("Turning it off deletes the remote copy once, even if the first try fails")
    func offDeletesRemote() async throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let remote = InMemorySnapshotPublisher()
        try service(state).setEnabled(true)
        _ = await service(state).run(publisher: remote)

        try service(state).setEnabled(false)
        #expect(try service(state).state().removePending)
        await remote.setFailing(true)
        guard case .failed = await service(state).run(publisher: remote) else { Issue.record("did not fail"); return }
        #expect(try service(state).state().removePending)

        await remote.setFailing(false)
        let later = now.addingTimeInterval(IPhoneFeedService.retryDelay + 1)
        #expect(await service(state, at: later).run(publisher: remote) == .removed)
        #expect(await remote.records.isEmpty)
        #expect(try service(state).state() == StoredIPhoneFeed())
        #expect(await service(state, at: later).run(publisher: remote) == .idle)
    }

    private func days(_ remote: InMemorySnapshotPublisher) async throws -> [CalendarEvent] {
        try await remote.records.values.filter { $0.kind == .calendarDay }
            .flatMap { try SnapshotCoding.decode(CalendarDay.self, from: $0.bytes).record.events }
    }

    @Test("Events go out only for chosen calendars, and a private one keeps only its time")
    func publishesChosenEvents() throws {
        let state = try fixture()
        func kinds() throws -> [SnapshotKind] {
            try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian)).map(\.kind)
        }
        #expect(!(try kinds()).contains(.calendarDay))

        try state.setIPhoneCalendar("cal", chosen: true)
        let records = try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian))
        let events = try records.filter { $0.kind == .calendarDay }
            .flatMap { try SnapshotCoding.decode(CalendarDay.self, from: $0.bytes).record.events }
        let open = try #require(events.first { $0.id == "a" }), hidden = try #require(events.first { $0.id == "b" })
        #expect(open.title == "Title a" && open.location == "Room 4" && open.calendarID == "cal" && open.response == .needsResponse)
        #expect(hidden.title == nil && hidden.location == nil && hidden.endsAt > hidden.startsAt)

        try state.setCalendarIgnored(true, calendarID: "cal")
        #expect(!(try kinds()).contains(.calendarDay))
    }

    @Test("Only events that can get a reminder carry a join link, and the Mac's reminder settings go along")
    func publishesJoinLinksAndSettings() throws {
        let zoom = "https://example.zoom.us/j/123456789"
        let state = try fixture(extra: [
            event("j", hour: 3, isPrivate: false, url: zoom),
            event("p", hour: 4, isPrivate: true, url: zoom),
            event("d", hour: 5, isPrivate: false, url: zoom, state: .declined),
            event("l", hour: 6, isPrivate: false, url: zoom, isAllDay: true),
            event("o", hour: -3, isPrivate: false, url: zoom),
        ])
        try state.setIPhoneCalendar("cal", chosen: true)
        try state.saveNotificationSettings(NotificationSettings(firstMinutes: 15, finalMinutes: 5, hideTitles: true))
        let records = try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian))
        let links = try records.filter { $0.kind == .calendarDay }
            .flatMap { try SnapshotCoding.decode(CalendarDay.self, from: $0.bytes).record.events }
            .reduce(into: [String: String]()) { $0[$1.id] = $1.joinURL }
        #expect(links == ["j": zoom])
        let settings = try #require(records.first { $0.kind == .reminderSettings })
        #expect(try SnapshotCoding.decode(ReminderSettings.self, from: settings.bytes).record.leadMinutes == [15, 5])
    }

    @Test("Changing the choice republishes, and unchoosing removes the events")
    func choiceIsRepublished() async throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let feed = service(state), remote = InMemorySnapshotPublisher()
        try feed.setEnabled(true)
        _ = await feed.run(publisher: remote)
        #expect(try await days(remote).isEmpty)

        try feed.setCalendar("Work", chosen: true)
        #expect(try feed.calendarChoices() == [.init(id: "cal", name: "Work", colorIndex: 11, isChosen: true)])
        guard case .published = await feed.run(publisher: remote) else { Issue.record("not published"); return }
        #expect(Set(try await days(remote).map(\.id)) == ["a", "b"])

        try feed.setCalendar("cal", chosen: false)
        guard case .published = await feed.run(publisher: remote) else { Issue.record("not republished"); return }
        #expect(try await days(remote).isEmpty)
        #expect(throws: (any Error).self) { try feed.setCalendar("Nowhere", chosen: true) }
    }

    @Test("The command line says why the feed is not available")
    func availabilityWording() {
        let app = URL(fileURLWithPath: "/Applications/Calopod.app")
        let signed = IPhoneFeedAvailability.check(app: app, exists: { $0.hasSuffix("embedded.provisionprofile") })
        #expect(signed == .available)
        #expect(IPhoneFeedAvailability.check(app: app, exists: { _ in false }) == .notSigned)
        #expect(IPhoneFeedAvailability.check(app: nil, exists: { _ in true }) == .noApp)
        #expect(IPhoneFeedAvailability.noApp.describe(StoredIPhoneFeed()) == "iPhone feed: not available (no app)")
        #expect(signed.describe(StoredIPhoneFeed()) == "iPhone feed: off")
        let item = iPhoneFeedDoctorItem(availability: .noApp, feed: { nil })
        #expect(item.item.kind == "skipped" && item.item.reason == "no-app" && item.warning == nil)
    }

    @Test("Each day is published worked out by the same code as the Mac")
    func publishesWorkedOutDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = zoned(12, 12)
        let slots: [(Double, Double, Double, Double)] = [
            (12, 10, 12, 11), (12, 10.5, 12, 11.5), (12, 17.5, 12, 18.5), (12, 22, 13, 2), (14, 9, 14, 10),
        ]
        let events = slots.enumerated().map { index, slot in
            let start = zoned(Int(slot.0), slot.1), end = zoned(Int(slot.2), slot.3)
            return event(
                "e\(index)", hour: start.timeIntervalSince(now) / 3600, isPrivate: false, state: .accepted,
                hours: end.timeIntervalSince(start) / 3600)
        }
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try state.saveConnection(StoredConnection(
            id: "c", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "c", bindings: [
            StoredCalendarBinding(
                id: "cal", connectionID: "c", providerCalendarID: "cal", displayLabel: "Work",
                isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
        ])
        try state.applyEventRefresh(
            connectionID: "c", calendarBindingID: "cal", windowStart: zoned(1, 0), windowEnd: zoned(31, 0),
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        // Sunday is a working day here, so the clock change falls inside working hours.
        let sunday = try WorkingHours.Day(startMinute: 540, endMinute: 1020)
        try state.saveWorkingHours(state.workingHours().setting(isoWeekday: 7, to: sunday))

        let records = try IPhoneFeedBuilder.records(repository: state, now: today, calendar: calendar)
        let days = try records.filter { $0.kind == .availabilityDay }.map {
            try SnapshotCoding.decode(CalopodSnapshot.AvailabilityDay.self, from: $0.bytes).record
        }
        #expect(days.count == IPhoneFeedBuilder.availabilityDays)
        let friday = days[0], saturday = days[1], sunday14 = days[2]
        #expect(friday.day == "2027-03-12" && friday.status == .mostlyFree && friday.overlaps == 1)
        #expect(friday.working == BusyInterval(start: zoned(12, 9), end: zoned(12, 17)))
        // Busy keeps only the working day. Time after 17:00 is listed as outside, and an event over
        // midnight is cut at the day's end.
        #expect(friday.busy == [BusyInterval(start: zoned(12, 10), end: zoned(12, 11.5))])
        #expect(friday.outside == [
            OutsideBlock(start: zoned(12, 17.5), end: zoned(12, 18.5), side: .after),
            OutsideBlock(start: zoned(12, 22), end: zoned(13, 0), side: .after),
        ])
        #expect(saturday.status == .dayOff && saturday.working == nil && saturday.free == [])
        #expect(saturday.busy == [] && saturday.outside == [OutsideBlock(start: zoned(13, 0), end: zoned(13, 2), side: .dayOff)])
        #expect(sunday14.status == .mostlyFree && sunday14.working == BusyInterval(start: zoned(14, 9), end: zoned(14, 17)))
        #expect(sunday14.free == [BusyInterval(start: zoned(14, 10), end: zoned(14, 17))])

        // The totals match `calopod availability` for the same days.
        let reports = try AvailabilityService(makeRepository: { state }).report(
            days: (0..<IPhoneFeedBuilder.availabilityDays).map { calendar.date(byAdding: .day, value: $0, to: zoned(12, 0))! },
            calendar: calendar)
        func seconds(_ list: [BusyInterval]) -> TimeInterval { list.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
        func outside(_ list: [OutsideBlock]?) -> TimeInterval {
            seconds((list ?? []).map { BusyInterval(start: $0.start, end: $0.end) })
        }
        for (published, report) in zip(days, reports) {
            #expect(seconds(published.free ?? []) == report.summary.freeSeconds)
            #expect(seconds(published.busy) == report.summary.busySeconds)
            #expect(outside(published.outside) == report.summary.outsideSeconds)
            #expect(published.overlaps == report.summary.overlaps)
        }
        #expect(seconds(sunday14.free ?? []) == 7 * 3600)
    }
}
#endif
