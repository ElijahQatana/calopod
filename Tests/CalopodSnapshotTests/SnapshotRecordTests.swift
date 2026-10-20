import CalopodDomain
import CalopodSnapshot
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let item = InboxItem(
    id: "abc123", reasons: [.needsRSVP, .conflict], changeOrderUncertain: true, title: "Planning",
    startsAt: now, endsAt: now.addingTimeInterval(3600), timeZoneIdentifier: "Europe/Berlin",
    sourceName: "Work", calendarID: "cal-1", response: .needsResponse, organizerName: "Sam Example",
    attendees: AttendeeSummary(total: 4, accepted: 2, tentative: 1, declined: 0),
    location: "Room 2", notes: "Agenda at https://example.com/agenda", url: "https://example.com/e",
    conflicts: [ConflictingEvent(title: "Review", startsAt: now, endsAt: now.addingTimeInterval(1800))])

private let day = AvailabilityDay(
    day: "2027-01-15", timeZoneIdentifier: "Europe/Berlin",
    busy: [BusyInterval(start: now, end: now.addingTimeInterval(3600))])

private let calendarDay = CalendarDay(
    day: "2027-01-15", timeZoneIdentifier: "Europe/Berlin",
    events: [
        CalendarEvent(
            id: "e1", calendarID: "cal-1", title: "Planning", startsAt: now, endsAt: now.addingTimeInterval(3600),
            location: "Room 2", response: .accepted, joinURL: "https://example.zoom.us/j/123456789"),
        CalendarEvent(id: "e2", calendarID: "cal-2", title: nil, startsAt: now, endsAt: now.addingTimeInterval(60), isAllDay: true, response: .unknown),
    ])

private let status = SyncStatus(
    lastSyncAt: now, issues: [SyncIssue(kind: .stale, calendarID: "cal-1", since: now), SyncIssue(kind: .partial)],
    runs: [SyncRunMark(at: now, failed: false), SyncRunMark(at: now.addingTimeInterval(900), failed: true)],
    calendarUpdates: [CalendarUpdate(calendarID: "cal-1", at: now)])

private let calendars = CalendarList(calendars: [
    CalendarEntry(id: "cal-1", name: "Work", colorIndex: 0),
    CalendarEntry(id: "cal-2", name: "Home", colorIndex: 11),
])

private let reminders = ReminderSettings(
    enabled: true, firstEnabled: true, firstMinutes: 10, finalEnabled: false, finalMinutes: 1, hideTitles: true)

private func roundTrip<R: SnapshotRecord>(_ record: R) throws -> R {
    let data = try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: now, record: record))
    return try SnapshotCoding.decode(R.self, from: data).record
}

@Test
func recordsSurviveARoundTrip() throws {
    #expect(try roundTrip(item) == item)
    #expect(try roundTrip(day) == day)
    #expect(try roundTrip(calendarDay) == calendarDay)
    #expect(try roundTrip(status) == status)
    #expect(try roundTrip(reminders) == reminders)
    #expect(try roundTrip(calendars) == calendars)
    #expect(try roundTrip(SyncStatus(lastSyncAt: nil)) == SyncStatus(lastSyncAt: nil))
}

@Test
func statusWithoutHistoryStillDecodes() throws {
    let old = Data(#"{"generatedAt":"2027-01-15T00:00:00Z","schemaVersion":\#(SnapshotSchema.currentVersion),"record":{"lastSyncAt":null,"issues":[]}}"#.utf8)
    let decoded = try SnapshotCoding.decode(SyncStatus.self, from: old).record
    #expect(decoded.runs == nil && decoded.calendarUpdates == nil)
}

@Test
func idsAreStable() {
    #expect(item.id == "abc123")
    #expect(day.id == "availability-2027-01-15")
    #expect(calendarDay.id == "calendar-day-2027-01-15")
    #expect(status.id == "sync-status")
    #expect(calendars.id == "calendars")
    #expect(reminders.id == "reminder-settings")
    let later = AvailabilityDay(day: "2027-01-15", timeZoneIdentifier: "UTC", busy: [])
    #expect(later.id == day.id)
}

@Test
func workedOutDayRoundTripsAndAnOlderDayStillDecodes() throws {
    let hours = BusyInterval(start: now, end: now.addingTimeInterval(8 * 3600))
    let full = AvailabilityDay(
        day: "2027-01-15", timeZoneIdentifier: "UTC", busy: [], working: hours, free: [hours], overlaps: 1, status: .tight,
        outside: [OutsideBlock(start: now, end: now.addingTimeInterval(1800), side: .before)])
    let data = try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: now, record: full))
    #expect(try SnapshotCoding.decode(AvailabilityDay.self, from: data).record == full)

    let old = #"{"schemaVersion":1,"generatedAt":"2027-01-15T08:00:00Z","record":{"day":"2027-01-15","timeZoneIdentifier":"UTC","busy":[]}}"#
    let decoded = try SnapshotCoding.decode(AvailabilityDay.self, from: Data(old.utf8)).record
    #expect(decoded.working == nil && decoded.free == nil && decoded.overlaps == nil && decoded.status == nil
        && decoded.outside == nil)
}

@Test
func newerVersionIsRefusedBeforeTheRecordIsRead() throws {
    // The record body is in a shape this reader could not decode.
    let json = #"{"schemaVersion":2,"generatedAt":"2027-01-15T08:00:00Z","record":{"moved":true}}"#
    #expect(throws: SnapshotError.newerVersion(found: 2, supported: SnapshotSchema.currentVersion)) {
        try SnapshotCoding.decode(InboxItem.self, from: Data(json.utf8))
    }
}

@Test
func unknownFieldsAreIgnored() throws {
    let data = try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: now, record: calendars))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var record = try #require(object["record"] as? [String: Any])
    var entries = try #require(record["calendars"] as? [[String: Any]])
    entries[0]["icon"] = "star"
    record["calendars"] = entries
    record["extra"] = ["a": 1]
    object["record"] = record
    object["note"] = "hello"
    let changed = try JSONSerialization.data(withJSONObject: object)
    #expect(try SnapshotCoding.decode(CalendarList.self, from: changed).record == calendars)
}

@Test
func colorIndexOutsideThePaletteIsRejected() {
    for index in [-1, 12] {
        let json = #"{"id":"c","name":"Work","colorIndex":\#(index)}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalendarEntry.self, from: Data(json.utf8))
        }
    }
}

@Test
func colorIdIsOptionalAndWinsOverTheIndex() throws {
    func decode(_ json: String) throws -> CalendarEntry {
        try JSONDecoder().decode(CalendarEntry.self, from: Data(json.utf8))
    }
    let older = try decode(#"{"id":"c","name":"Work","colorIndex":10}"#)
    #expect(older.color == nil && older.paletteEntry.id == "indigo")
    let newer = try decode(#"{"id":"c","name":"Work","colorIndex":3,"color":"amber"}"#)
    #expect(newer.paletteEntry.id == "amber")
    #expect(try decode(#"{"id":"c","name":"Work","colorIndex":3,"color":"mauve"}"#).paletteEntry.id == "gray")
    let sent = CalendarEntry(id: "c", name: "Work", colorIndex: 4, color: "red", destination: true, source: false)
    #expect(try decode(String(decoding: JSONEncoder().encode(sent), as: UTF8.self)) == sent)
    #expect(older.destination == nil && older.source == nil)
}

@Test
func recordsCarryNoAddressesOrTokens() throws {
    let text = String(decoding: try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: now, record: item)), as: UTF8.self)
    #expect(!text.contains("@"))
    #expect(!text.lowercased().contains("token"))
}

@Test
func payloadsUseTheRecordIDAndReplaceTheRemoteSet() async throws {
    let first = try SnapshotPayload(day, kind: .availabilityDay, at: now)
    let second = try SnapshotPayload(status, kind: .syncStatus, at: now)
    #expect(first.recordName == "availability-2027-01-15" && first.schemaVersion == SnapshotSchema.currentVersion)
    let remote = InMemorySnapshotPublisher()
    try await remote.replaceAll(with: [first, second])
    try await remote.replaceAll(with: [second])
    #expect(await remote.records.keys.sorted() == ["sync-status"])
    try await remote.deleteAll()
    #expect(await remote.records.isEmpty)
}

@Test
func reminderLeadsFollowTheSwitches() {
    #expect(reminders.leadMinutes == [10])
    let both = ReminderSettings(enabled: true, firstEnabled: true, firstMinutes: 15, finalEnabled: true, finalMinutes: 2, hideTitles: false)
    #expect(both.leadMinutes == [15, 2])
    let off = ReminderSettings(enabled: false, firstEnabled: true, firstMinutes: 15, finalEnabled: true, finalMinutes: 2, hideTitles: false)
    #expect(off.leadMinutes.isEmpty)
}

@Test
func anEventWithoutAJoinLinkStillDecodes() throws {
    let json = #"{"id":"e","calendarID":"c","startsAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T09:00:00Z","isAllDay":false,"response":"accepted"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(CalendarEvent.self, from: Data(json.utf8)).joinURL == nil)
}

@Test
func copyFlagIsOptional() throws {
    func decode(_ json: String) throws -> CalendarEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(CalendarEvent.self, from: Data(json.utf8))
    }
    let older = try decode(#"{"id":"e","calendarID":"c","startsAt":0,"endsAt":60,"isAllDay":false,"response":"accepted"}"#)
    #expect(!older.isCopy)
    #expect(try decode(#"{"id":"e","calendarID":"c","startsAt":0,"endsAt":60,"isAllDay":false,"response":"accepted","copy":true}"#).isCopy)
}
