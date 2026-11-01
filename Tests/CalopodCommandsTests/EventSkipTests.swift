import ArgumentParser
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite struct EventSkipTests {
    @Test("Skipping and undoing, by event id or by the id in the skipped list")
    func skipAndUndo() throws {
        let f = try Fixture()
        try f.refresh([f.event("a"), f.event("s1", series: "weekly"), f.event("s2", series: "weekly"), f.event("s3", series: "monthly")])
        _ = try EventSkipService.skip(eventID: "a", wholeSeries: false, repository: f.repository, now: Date(timeIntervalSince1970: 1))
        _ = try EventSkipService.skip(eventID: "s1", wholeSeries: true, repository: f.repository, now: Date(timeIntervalSince1970: 2))
        _ = try EventSkipService.skip(eventID: "s3", wholeSeries: false, repository: f.repository, now: Date(timeIntervalSince1970: 3))

        let listed = try EventSkipService.skipped(repository: f.repository)
        #expect(listed.map { $0.event?.sourceKeyHash } == ["a", "s1", "s3"])
        #expect(try EventSkipService.isSkipped(eventID: "s2", repository: f.repository))
        #expect(try !EventSkipService.isSkipped(eventID: "s2x", repository: f.repository))
        let items = listed.map(EventsSkippedCommand.item)
        #expect(items.map(\.label) == ["Example", "Example (series)", "Example (one occurrence)"])

        _ = try EventSkipService.unskip("s2", repository: f.repository)
        _ = try EventSkipService.unskip(items[0].id, repository: f.repository)
        #expect(try EventSkipService.skipped(repository: f.repository).map { $0.event?.sourceKeyHash } == ["s3"])
    }

    @Test("A skip names an event that is there, and undoing needs a skip", arguments: [
        ("missing", false, "No event with that id was found."), ("a", true, "That event is not part of a series."),
    ])
    func refusals(id: String, series: Bool, message: String) throws {
        let f = try Fixture()
        try f.refresh([f.event("a")])
        #expect {
            try EventSkipService.skip(eventID: id, wholeSeries: series, repository: f.repository)
        } throws: { ($0 as? ValidationError)?.message.hasPrefix(message) == true }
        #expect {
            try EventSkipService.unskip("a", repository: f.repository)
        } throws: { ($0 as? ValidationError)?.message == "That event is not skipped." }
    }

    @Test("A skip is still there after restarting, and an event outside the synced range is listed")
    func restart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        do {
            let f = try Fixture(path: path)
            try f.refresh([f.event("a")])
            _ = try EventSkipService.skip(eventID: "a", wholeSeries: false, repository: f.repository)
            try f.refresh([], removed: ["a"])
        }
        let restarted = LocalStateRepository(database: try CalopodDatabase(path: path))
        let listed = try EventSkipService.skipped(repository: restarted)
        #expect(listed.count == 1 && listed[0].event == nil)
        #expect(EventsSkippedCommand.item(listed[0]).label == "Not in the synced range")
    }

    @Test("The events command still runs without a subcommand")
    func plainEvents() throws {
        #expect(try CalopodRoot.parseAsRoot(["events", "--cached"]) is EventsCommand)
        #expect(try CalopodRoot.parseAsRoot(["events", "skip", "a", "--series"]) is EventsSkipCommand)
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
    func event(_ key: String, series: String? = nil) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar", providerEventID: key,
            recurrenceID: series.map { _ in "occurrence-\(key)" }, startsAt: Date(timeIntervalSince1970: 2000), endsAt: Date(timeIntervalSince1970: 3000),
            isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: "Example", contentFingerprint: "example",
            providerUpdatedAt: nil, providerSeriesID: series)
    }
    func refresh(_ events: [StoredNormalizedInstance], removed: [String] = []) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: start, windowEnd: end,
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], now: Date(), removedSourceKeyHashes: removed)
    }
}
