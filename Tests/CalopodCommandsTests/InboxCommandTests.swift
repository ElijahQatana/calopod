@testable import CalopodCommands
import ArgumentParser
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import Foundation
import Testing

@Suite struct InboxCommandTests {
    @Test func parsing() throws {
        #expect(try CalopodRoot.parseAsRoot(["inbox"]) is InboxCommand)
        #expect(try CalopodRoot.parseAsRoot(["inbox", "activity", "--all", "--exclude-maybe", "--conflicts", "--format", "json"]) is InboxActivityCommand)
        for name in ["inspect", "acknowledge"] {
            #expect(throws: (any Error).self) { try CalopodRoot.parseAsRoot(["inbox", name]) }
        }
        #expect(throws: (any Error).self) { try InboxCLI.parse("event") }
        #expect(throws: (any Error).self) { try InboxCLI.parse("event:0") }
        #expect(try InboxCLI.parse("event:3").1 == 3)
        var dates = try DateRangeOptions.parse([]); dates.day = "2026-02-30"
        #expect(throws: (any Error).self) { try dates.resolve(default: .none) }
        dates.day = "2026-11-01"; dates.from = "2026-11-01"
        #expect(throws: (any Error).self) { try dates.resolve(default: .none) }
        dates.day = nil; dates.timezone = "invalid"
        #expect(throws: (any Error).self) { try dates.resolve(default: .none) }
    }

    @Test func snoozeHidesListsAndUnsnoozes() throws {
        #expect(try CalopodRoot.parseAsRoot(["inbox", "snooze", "event:1", "--until", "later"]) is InboxSnoozeCommand)
        #expect(try CalopodRoot.parseAsRoot(["inbox", "unsnooze", "event:1"]) is InboxUnsnoozeCommand)
        #expect(try CalopodRoot.parseAsRoot(["inbox", "--snoozed"]) is InboxCommand)
        #expect(throws: (any Error).self) { try CalopodRoot.parseAsRoot(["inbox", "snooze", "event:1"]) }
        #expect(throws: (any Error).self) { try InboxCLI.snoozeChoice("soon") }
        #expect(try InboxCLI.snoozeChoice("tomorrow") == .tomorrow)

        let f = try Fixture()
        let zero = Date(timeIntervalSince1970: 0)
        try f.refresh([f.event("maybe", response: .tentative), f.event("needs", response: .needsResponse)])
        #expect(throws: (any Error).self) { try InboxCLI.snooze("needs:2", until: .tomorrow, repository: f.repository, now: zero) }
        #expect(throws: (any Error).self) { try InboxCLI.snooze("needs:1", until: .day(zero.addingTimeInterval(-86400 * 5)), repository: f.repository, now: zero) }
        #expect(throws: (any Error).self) { try InboxCLI.unsnooze("needs:1", repository: f.repository) }
        _ = try InboxCLI.snooze("maybe:1", until: .tomorrow, repository: f.repository, now: zero)
        #expect(try f.list().items?.map(\.id) == ["needs:1"])
        let snoozed = try f.list(snoozed: true)
        #expect(snoozed.items?.map(\.id) == ["maybe:1"])
        #expect(snoozed.items?.first?.inbox?.snoozedUntil != nil)
        _ = try InboxCLI.unsnooze("maybe:1", repository: f.repository)
        #expect(try f.list().items?.map(\.id) == ["maybe:1", "needs:1"])
        #expect(try f.list(snoozed: true).count == 0)
    }

    @Test func listsAndFormats() throws {
        let f = try Fixture()
        #expect(try f.list().count == 0)
        try f.refresh([f.event("maybe", response: .tentative), f.event("needs", response: .needsResponse)])
        try f.refresh([f.event("maybe", response: .tentative, notes: "Edit"), f.event("needs", response: .needsResponse)])
        let payload = try f.list()
        #expect(payload.items?.count == 2)
        #expect(payload.items?.first?.inbox?.reasons.contains("conflict") == true)
        #expect(payload.items?.first?.inbox?.reasons.contains("maybe") == true)
        var options = try InboxOptions.parse([]); options.excludeMaybe = true
        #expect(try f.list(options).items?.map(\.id) == ["needs:1"])
        #expect(try f.list(options, activity: true).count == 0)
        options.excludeMaybe = false; options.calendar = "missing"
        #expect(throws: (any Error).self) { try f.list(options) }
        options.calendar = "calendar"; options.connection = "connection"
        #expect(try f.list(options).count == 2)
        for format in [OutputFormat.human, .json] {
            let text = try OutputRenderer.render(command: "inbox", payload: payload, format: format, showIDs: true)
            #expect(text.contains("maybe:2"))
            #expect(text.contains("conflict"))
            if format == .json { #expect(try JSONDecoder().decode(CommandEnvelope.self, from: Data(text.utf8)).data == payload) }
        }
        let noIDs = try OutputRenderer.render(command: "inbox", payload: payload, format: .human)
        #expect(!noIDs.contains("maybe:2"))
    }

    @Test func scopeKeepsOtherConflictSources() throws {
        let f = try Fixture()
        try f.repository.replaceCalendarBindings(connectionID: "connection", bindings: [
            StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source", displayLabel: "Example", isSelected: true, isReadOnly: true),
            StoredCalendarBinding(id: "other", connectionID: "connection", providerCalendarID: "other", displayLabel: "Other", isSelected: true, isReadOnly: true)
        ])
        try f.refresh([f.event("event")])
        let other = StoredNormalizedInstance(sourceKeyHash: "other", connectionID: "connection", calendarBindingID: "other", providerEventID: "other", recurrenceID: nil,
            startsAt: f.start, endsAt: f.start.addingTimeInterval(1000), isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false,
            title: "Other example", contentFingerprint: "example", providerUpdatedAt: nil, currentUserResponse: EventResponse(state: .accepted))
        try f.repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "other", windowStart: f.start, windowEnd: f.end,
            instances: [other], cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        let options = try InboxOptions.parse(["--calendar", "calendar", "--conflicts"])
        #expect(try f.list(options).items?.map(\.id) == ["event:1"])
        #expect(try f.list(options).items?.first?.inbox?.conflicts.first?.eventID == "other")
        _ = try f.repository.setCalendarSelection(id: "other", isSelected: false)
        #expect(try f.list(options).count == 0)
    }

    @Test func revisionReviewAndRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try Fixture(path: url.path)
        try f.refresh([f.event("event", response: .tentative)])
        try f.refresh([f.event("event", response: .tentative, notes: "First")])
        let detail = try InboxCLI.inspect("event:2", repository: f.repository)
        #expect(detail.items?.first?.inbox?.changedFields == ["notes"])
        #expect(try f.list(activity: true).count == 1)
        _ = try InboxCLI.acknowledge("event:2", repository: f.repository)
        try f.refresh([f.event("event", response: .tentative, notes: "Second")])
        _ = try InboxCLI.acknowledge("event:2", repository: f.repository)
        let restarted = LocalStateRepository(database: try CalopodDatabase(path: url.path))
        #expect(try InboxCLI.list(repository: restarted, options: try InboxOptions.parse([]), range: nil, activity: true).items?.map(\.id) == ["event:3"])
        #expect(try f.list(activity: true, all: true).count == 2)
        #expect(try f.list().items?.first?.inbox?.reasons.contains("maybe") == true)
        #expect(try f.list().items?.first?.inbox?.reasons.contains("changed-after-response") == true)
        #expect(throws: (any Error).self) { try InboxCLI.acknowledge("event:99", repository: f.repository) }
    }

    @Test func reviewingNewRevisionLeavesOldActivityUnread() throws {
        let f = try Fixture()
        try f.refresh([f.event("event")])
        try f.refresh([f.event("event", notes: "First")])
        try f.refresh([f.event("event", notes: "Second")])
        _ = try InboxCLI.acknowledge("event:3", repository: f.repository)
        let unread = try f.list(activity: true)
        #expect(unread.items?.map(\.id) == ["event:2"])
        #expect(unread.items?.first?.inbox?.reviewed == false)
    }

    @Test func movedAndRemovedActivity() throws {
        let f = try Fixture()
        try f.refresh([f.event("event")])
        try f.refresh([f.event("event", start: 5000)])
        let old = ResolvedDateRange(window: try SyncWindow(start: f.start, end: f.start.addingTimeInterval(1000)), timeZoneIdentifier: "UTC")
        #expect(try f.list(range: old, activity: true).count == 1)
        let adjacent = ResolvedDateRange(window: try SyncWindow(start: f.start.addingTimeInterval(1000), end: f.start.addingTimeInterval(2000)), timeZoneIdentifier: "UTC")
        #expect(try f.list(range: adjacent, activity: true).count == 0)
        try f.refresh([], removed: ["event"])
        #expect(try f.list(activity: true).items?.first?.cancelled == true)
        #expect(try InboxCLI.inspect("event:3", repository: f.repository).items?.first?.startsAt == InboxCLI.date(Date(timeIntervalSince1970: 5000)))
    }

    @Test func mappedCopiesStayOutOfActivityAndInspect() throws {
        let f = try Fixture()
        try f.refresh([f.event("copy")])
        try f.refresh([f.event("copy", notes: "Edit")])
        #expect(try f.list(activity: true).count == 1)
        try f.repository.saveArm(StoredArm(id: "arm", configurationID: "default", sourceBindingIDs: ["calendar"], targetBindingID: "calendar", ruleMode: .busy))
        try f.repository.saveMirrorMapping(StoredMirrorMapping(mirrorKey: "mapping", armID: "arm", sourceKeyHash: "original", providerEventID: "copy", providerVersion: nil, desiredFingerprint: "example", ownershipKeyID: "example", updatedAt: f.start))
        #expect(try f.list(activity: true).count == 0)
        #expect(throws: (any Error).self) { try InboxCLI.inspect("copy:2", repository: f.repository) }
    }

    @Test func aReadMadeNowCoversTheWeekAndAShortOneNamesItsGap() async throws {
        let f = try Fixture()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 19, minute: 30))!
        let week = utc.date(from: DateComponents(year: 2026, month: 10, day: 18))!..<utc.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let sources = try selectedCalendarSources(connectionID: nil, calendarID: nil, repository: f.repository)
        let read = { (window: SyncWindow) async in
            _ = await refreshCalendarSources(sources, from: window.start, through: window.end, repository: f.repository, readSource: { _, _, _ in
                ProviderEventPage(events: [], nextSyncToken: nil, refreshMode: .full)
            })
        }
        func status(at when: Date) throws -> (String, String?) {
            let source = try #require(try f.repository.inboxContextSnapshot().sources.first)
            let detail = try #require(InboxCLI.source(source, now: when, range: week).inbox)
            return (detail.status, detail.gap)
        }

        await read(try CalendarReadWindow.containing(now, calendar: utc))
        #expect(try status(at: Date()).0 != "unknown")
        let covered = try #require(try f.repository.inboxCoverage(connectionID: "connection", calendarBindingID: "calendar"))
        #expect(covered.startsAt <= week.lowerBound && covered.endsAt >= week.upperBound)

        // The old automatic window (a day back, four ahead) stops on Thursday.
        await read(try SyncWindow(start: utc.date(from: DateComponents(year: 2026, month: 10, day: 17))!,
                                  end: utc.date(from: DateComponents(year: 2026, month: 10, day: 23))!))
        let short = try status(at: Date())
        #expect(short.0 == "partial")
        #expect(short.1?.hasPrefix("read until") == true)
    }

    @Test func partialRefreshReadsOnly() async throws {
        let f = try Fixture()
        try f.repository.replaceCalendarBindings(connectionID: "connection", bindings: ["calendar", "failed"].map {
            StoredCalendarBinding(id: $0, connectionID: "connection", providerCalendarID: $0 == "calendar" ? "source" : $0, displayLabel: "Example", isSelected: true, isReadOnly: true)
        })
        let sources = try selectedCalendarSources(connectionID: nil, calendarID: nil, repository: f.repository)
        let refresh = await refreshCalendarSources(sources, from: f.start, through: f.end, repository: f.repository, readSource: { source, _, _ in
            if source.calendar.id == "failed" { throw ProviderFailure.temporaryFailure(retryAfterSeconds: nil) }
            return ProviderEventPage(events: [], nextSyncToken: nil, refreshMode: .full)
        })
        #expect(refresh.failedSourceCount == 1)
        #expect(refresh.refreshedSourceCount == 1)
        #expect(try f.repository.inboxCoverage(connectionID: "connection", calendarBindingID: "failed") == nil)
        #expect(try f.repository.inboxCoverage(connectionID: "connection", calendarBindingID: "calendar") != nil)
        let payload = inboxRefreshPayload(refresh, range: ResolvedDateRange(window: try SyncWindow(start: f.start, end: f.end), timeZoneIdentifier: "UTC"))
        #expect(payload.status == "partial")
        #expect(!payload.message.contains("calendar"))
    }
}

private struct Fixture {
    let repository: LocalStateRepository
    let start = Date(timeIntervalSince1970: 1000)
    let end = Date(timeIntervalSince1970: 20000)
    init(path: String? = nil) throws {
        repository = LocalStateRepository(database: try path.map { try CalopodDatabase(path: $0) } ?? CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "google", displayLabel: "Example", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source", displayLabel: "Example", isSelected: true, isReadOnly: true)])
    }
    func event(_ key: String, response: EventResponseState = .accepted, notes: String? = nil, start: Double = 1000) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar", providerEventID: key, recurrenceID: nil,
            startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1000), isAllDay: false, availability: "busy", isCancelled: false,
            isPrivate: false, title: "Example", contentFingerprint: "example", providerUpdatedAt: nil, notes: notes, currentUserResponse: EventResponse(state: response))
    }
    func refresh(_ events: [StoredNormalizedInstance], removed: [String] = []) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: start, windowEnd: end,
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], now: Date(), removedSourceKeyHashes: removed)
    }
    func list(_ options: InboxOptions? = nil, range: ResolvedDateRange? = nil, activity: Bool = false, all: Bool = false,
              snoozed: Bool = false) throws -> CommandPayload {
        try InboxCLI.list(repository: repository, options: try options ?? InboxOptions.parse([]), range: range, activity: activity, all: all,
            snoozed: snoozed, now: Date(timeIntervalSince1970: 0))
    }
}
