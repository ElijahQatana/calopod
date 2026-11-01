import CalopodDomain
import CalopodStore
@testable import CalopodSync
import Foundation
import Testing

@Suite("Inbox snooze")
struct InboxSnoozeTests {
    enum Item: CaseIterable { case needsRSVP, maybe, changed, conflict }

    /// A listed event "event" that starts at 10000, with the reason `item` names.
    func listed(_ item: Item) throws -> AttentionFixture {
        let f = try AttentionFixture()
        switch item {
        case .needsRSVP: try f.refresh([f.event(response: .needsResponse)])
        case .maybe: try f.refresh([f.event(response: .tentative)])
        case .changed:
            try f.refresh([f.event(response: .accepted)])
            try f.refresh([f.event(response: .accepted, notes: "Changed")])
        case .conflict:
            try f.refresh([f.event(response: .accepted), f.event(key: "other", response: .accepted, start: 10500)])
        }
        return f
    }

    func snooze(_ f: AttentionFixture, until: Double, at now: Double = 1000) throws {
        let snapshot = try f.repository.inboxContextSnapshot()
        let value = try #require(InboxAttentionQuery.snooze("event", until: date(until), in: snapshot, asOf: date(now),
                                                           freshnessCutoff: date(100)))
        try f.repository.snoozeInboxItem(value, now: date(now))
    }

    func rows(_ f: AttentionFixture, at now: Double, _ scope: InboxSnoozeScope = .hide) throws -> [String] {
        try f.query(InboxAttentionFilter(asOf: date(now), snoozed: scope)).rows
            .map(\.item.event.sourceKeyHash).filter { $0 == "event" }
    }

    @Test("A snoozed item is hidden until it is due, for every kind including Maybe", arguments: Item.allCases)
    func hidesUntilDue(item: Item) throws {
        let f = try listed(item)
        #expect(try rows(f, at: 1000) == ["event"])
        try snooze(f, until: 5000)
        #expect(try rows(f, at: 1000).isEmpty)
        #expect(try rows(f, at: 4999).isEmpty)
        #expect(try rows(f, at: 4999, .only) == ["event"])
        #expect(try rows(f, at: 5000) == ["event"])
        #expect(try rows(f, at: 5000, .only).isEmpty)
    }

    @Test func snoozeSendsAndAcknowledgesNothing() throws {
        let f = try listed(.changed)
        let before = try #require(try f.repository.inboxObservation(sourceKeyHash: "event"))
        try snooze(f, until: 5000)
        #expect(try f.repository.inboxObservation(sourceKeyHash: "event") == before)
        try f.repository.unsnoozeInboxItem(sourceKeyHash: "event")
        #expect(try rows(f, at: 1000) == ["event"])
        #expect(try f.query(InboxAttentionFilter(asOf: date(1000))).rows.first?.reasons.contains(.changedAfterResponse) == true)
    }

    @Test func newerChangeBringsItBack() throws {
        let f = try listed(.maybe)
        try snooze(f, until: 5000)
        try f.refresh([f.event(response: .tentative, notes: "New agenda")])
        #expect(try rows(f, at: 2000) == ["event"])
    }

    @Test func newConflictBringsItBackButAKnownOneDoesNot() throws {
        let known = try listed(.conflict)
        try snooze(known, until: 5000)
        #expect(try rows(known, at: 2000).isEmpty)

        let f = try listed(.maybe)
        try snooze(f, until: 5000)
        try f.refresh([f.event(response: .tentative), f.event(key: "other", response: .accepted, start: 10500)])
        #expect(try f.repository.inboxObservation(sourceKeyHash: "event")?.revision == 1)
        #expect(try rows(f, at: 2000) == ["event"])
    }

    @Test func startedEventComesBack() throws {
        let f = try listed(.needsRSVP)
        try snooze(f, until: 50000)
        #expect(try rows(f, at: 9999).isEmpty)
        #expect(try rows(f, at: 10000) == ["event"])
    }

    @Test func snoozeEndingWhileClosedShowsOnNextLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AttentionFixture(path: url.path)
        try f.refresh([f.event(response: .tentative)])
        try snooze(f, until: 5000)
        let reopened = try AttentionFixture(path: url.path, reopening: true)
        #expect(try rows(reopened, at: 2000).isEmpty)
        #expect(try rows(reopened, at: 6000) == ["event"])
    }

    @Test func snoozingAnUnlistedItemDoesNothing() throws {
        let f = try listed(.needsRSVP)
        let snapshot = try f.repository.inboxContextSnapshot()
        #expect(InboxAttentionQuery.snooze("missing", until: date(5000), in: snapshot, asOf: date(1000), freshnessCutoff: date(100)) == nil)
    }

    @Test func choices() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let table: [(InboxSnoozeChoice, Date, Date?)] = [
            (.laterToday, at(5, 9), at(5, 12)),
            (.laterToday, at(5, 22), at(5, 23, 59).addingTimeInterval(59)),
            (.tomorrow, at(5, 22), at(6, 8)),
            (.day(at(9, 15)), at(5, 9), at(9, 8)),
            (.day(at(5, 15)), at(5, 9), nil),
            (.day(at(4, 15)), at(5, 9), nil),
        ]
        for (choice, now, expected) in table {
            #expect(choice.until(from: now, calendar: calendar) == expected)
        }
    }

    func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
}
