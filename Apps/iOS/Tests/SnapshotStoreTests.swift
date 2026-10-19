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
