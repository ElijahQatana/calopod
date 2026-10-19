import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

@MainActor
struct SnapshotStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cache() -> SnapshotCache {
        SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
    }

    @Test func showsFreshFixture() async {
        let store = SnapshotStore(reader: FixtureReader(scenario: .fresh, now: now), cache: cache())
        await store.refresh()
        guard case .content(let snapshot, let offline) = store.phase else { Issue.record("no content"); return }
        #expect(!offline)
        #expect(!Age.isStale(snapshot.publishedAt, now: now))
    }

    @Test func noCalendarsFixtureHasNoEvents() async {
        let store = SnapshotStore(reader: FixtureReader(scenario: .noCalendars, now: now), cache: cache())
        await store.refresh()
        guard case .content(let snapshot, _) = store.phase else { Issue.record("no content"); return }
        #expect(snapshot.days.isEmpty)
        #expect(!snapshot.availability.isEmpty)
    }

    @Test func emptyStatesComeFromTheReader() async {
        for (scenario, phase) in [(FixtureReader.Scenario.sharingOff, SnapshotStore.Phase.sharingOff), (.nothingPublished, .nothingPublished)] {
            let store = SnapshotStore(reader: FixtureReader(scenario: scenario, now: now), cache: cache())
            await store.refresh()
            #expect(store.phase == phase)
        }
    }

    @Test func keepsCachedCopyWhenOffline() async {
        let cache = cache()
        await SnapshotStore(reader: FixtureReader(now: now), cache: cache).refresh()
        let store = SnapshotStore(reader: FixtureReader(scenario: .offline, now: now), cache: cache)
        await store.refresh()
        guard case .content(_, let offline) = store.phase else { Issue.record("cache not used"); return }
        #expect(offline)
    }

    @Test func failsWithoutCache() async {
        let store = SnapshotStore(reader: FixtureReader(scenario: .offline), cache: cache())
        await store.refresh()
        #expect(store.phase == .failed)
    }

    @Test func turningSharingOffDropsTheCache() async {
        let cache = cache()
        await SnapshotStore(reader: FixtureReader(now: now), cache: cache).refresh()
        await SnapshotStore(reader: FixtureReader(scenario: .sharingOff), cache: cache).refresh()
        #expect(cache.load() == nil)
    }
}

struct CloudKitAssembleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payloads(_ snapshot: Snapshot) throws -> [(kind: String, data: Data)] {
        func wrap<R: SnapshotRecord>(_ record: R) throws -> Data {
            try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: snapshot.publishedAt, record: record))
        }
        return try snapshot.inbox.map { ("inbox-item", try wrap($0)) }
            + snapshot.availability.map { ("availability-day", try wrap($0)) }
            + snapshot.days.map { ("calendar-day", try wrap($0)) }
            + [("calendars", try wrap(CalendarList(calendars: snapshot.calendars))), ("sync-status", try wrap(snapshot.status))]
    }

    @Test func noRecordsMeansNothingPublished() throws {
        #expect(try CloudKitReader.assemble([]) == .nothingPublished)
    }

    @Test func recordsBecomeOneSnapshot() throws {
        let fixture = FixtureReader.snapshot(publishedAt: now, now: now)
        guard case .snapshot(let result) = try CloudKitReader.assemble(try payloads(fixture)) else { Issue.record("no snapshot"); return }
        #expect(result.inbox.count == fixture.inbox.count)
        #expect(result.availability.count == fixture.availability.count)
        #expect(result.days == fixture.days)
        #expect(!result.days.isEmpty)
        #expect(result.calendars == fixture.calendars)
        #expect(result.status == fixture.status)
    }

    @Test func noCalendarDaysMeansNoEvents() throws {
        var fixture = FixtureReader.snapshot(publishedAt: now, now: now)
        fixture.days = []
        guard case .snapshot(let result) = try CloudKitReader.assemble(try payloads(fixture)) else { Issue.record("no snapshot"); return }
        #expect(result.days.isEmpty)
        #expect(result.inbox.count == fixture.inbox.count)
    }

    @Test func cacheFromBeforeEventsStillLoads() throws {
        let cache = SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        cache.save(FixtureReader.snapshot(publishedAt: now, now: now))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as! [String: Any]
        json["days"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: cache.url)
        #expect(cache.load()?.days == [])
        #expect(cache.load()?.inbox.count == 5)
    }

    @Test func newerSchemaNeedsANewerApp() throws {
        let data = try SnapshotCoding.encode(
            SnapshotEnvelope(generatedAt: now, record: SyncStatus(lastSyncAt: now), schemaVersion: SnapshotSchema.currentVersion + 1))
        #expect(throws: ReaderError.needsNewerApp) { try CloudKitReader.assemble([("sync-status", data)]) }
    }
}

struct SignedOutTests {
    private struct Signed: ICloudAvailability { let isSignedIn: Bool }

    @Test func readerRefusesWithoutAnIdentity() async {
        await #expect(throws: ReaderError.signedOut) {
            try await CloudKitReader(iCloud: Signed(isSignedIn: false)).read()
        }
    }

    @MainActor @Test func storeShowsSignedOutWithoutCache() async {
        let cache = SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        let store = SnapshotStore(reader: CloudKitReader(iCloud: Signed(isSignedIn: false)), cache: cache)
        await store.refresh()
        #expect(store.phase == .signedOut)
    }
}

struct AgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func shortText() {
        for (seconds, expected) in [(30.0, "just now"), (720, "12m"), (3 * 3600, "3h"), (2 * 86400, "2d")] {
            #expect(Age.short(now.addingTimeInterval(-seconds), now: now) == expected)
        }
    }

    @Test func staleAfterTwoHours() {
        #expect(!Age.isStale(now.addingTimeInterval(-3600), now: now))
        #expect(Age.isStale(now.addingTimeInterval(-3 * 3600), now: now))
        #expect(Age.lastUpdated(now.addingTimeInterval(-3 * 3600), now: now) == "Last updated from your Mac 3h ago")
    }
}
