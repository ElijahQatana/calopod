@testable import CalopodStore
import Foundation
import Testing

@Suite struct SkippedEventStoreTests {
    @Test("A skip covers a single event, a whole series or one occurrence", arguments: [
        (event("a"), false, event("a"), true),
        (event("a"), false, event("b"), false),
        (event("a", calendar: "other"), false, event("a"), false),
        (event("a", externalID: "uid"), false, event("a2", externalID: "uid"), true),
        (event("s1", series: "weekly"), true, event("s2", series: "weekly"), true),
        (event("s1", series: "weekly"), true, event("s3", series: "monthly"), false),
        (event("s1", series: "weekly"), false, event("s1", series: "weekly"), true),
        (event("s1", series: "weekly"), false, event("s2", series: "weekly"), false),
    ] as [(StoredNormalizedInstance, Bool, StoredNormalizedInstance, Bool)])
    func matching(skipped: StoredNormalizedInstance, series: Bool, other: StoredNormalizedInstance, matches: Bool) {
        #expect(EventSkip(skipped, wholeSeries: series, isEventKit: false).matches(other) == matches)
    }

    @Test("Only a server id or a series id travels between Macs", arguments: [
        (event("a"), true, false), (event("a"), false, true),
        (event("a", externalID: "uid"), true, true), (event("s", series: "weekly"), true, true),
    ] as [(StoredNormalizedInstance, Bool, Bool)])
    func portable(event: StoredNormalizedInstance, isEventKit: Bool, portable: Bool) {
        #expect(EventSkip(event, wholeSeries: false, isEventKit: isEventKit).isPortable == portable)
    }

    @Test("Skips are saved once, removed on request and kept after reopening")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let first = EventSkip(event("a"), wholeSeries: false, isEventKit: false, now: Date(timeIntervalSince1970: 10))
        let second = EventSkip(event("s", series: "weekly"), wholeSeries: true, isEventKit: false, now: Date(timeIntervalSince1970: 20))
        do {
            let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
            try repository.addEventSkip(first)
            try repository.addEventSkip(first)
            try repository.addEventSkip(second)
        }
        let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try reopened.eventSkips() == [first, second])
        try reopened.removeEventSkip(first)
        #expect(try reopened.eventSkips() == [second])
    }
}

private func event(
    _ key: String, calendar: String = "source", series: String? = nil, externalID: String? = nil
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(key)", connectionID: "connection", calendarBindingID: calendar,
        providerEventID: "id-\(key)", recurrenceID: series.map { _ in "occurrence-\(key)" },
        startsAt: Date(timeIntervalSince1970: 2_000), endsAt: Date(timeIntervalSince1970: 3_000),
        isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: nil,
        contentFingerprint: "f-\(key)", providerUpdatedAt: nil, providerSeriesID: series, providerExternalID: externalID)
}
