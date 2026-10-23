import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

@MainActor
struct FeedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ id: String, shared: Bool = false, minutesAgo: Double = 0, level: SnapshotLevel = .full) -> Feed {
        Feed(id: id, name: id, isShared: shared, level: level, publishedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func snapshot() async throws -> Snapshot {
        guard case .snapshot(let snapshot) = try await FixtureReader(now: now).read() else { throw ReaderError.unavailable }
        return snapshot
    }

    @Test func ownFeedsComeBeforeSharedOnes() {
        let feeds = [feed("shared", shared: true), feed("old", minutesAgo: 30), feed("new", minutesAgo: 5)]
        #expect(FeedChoice.pick(feeds, preferred: nil)?.id == "new")
        #expect(FeedChoice.ordered(feeds).map(\.id) == ["new", "old", "shared"])
    }

    @Test func sharedIsTheFallbackAndAChoiceWins() {
        let shared = [feed("a", shared: true, minutesAgo: 20), feed("b", shared: true, minutesAgo: 2)]
        #expect(FeedChoice.pick(shared, preferred: nil)?.id == "b")
        #expect(FeedChoice.pick(shared + [feed("mine")], preferred: "a")?.id == "a")
        #expect(FeedChoice.pick(shared, preferred: "gone")?.id == "b")
        #expect(FeedChoice.pick([], preferred: nil) == nil)
    }

    @Test func labelsSayWhenOnlyBusyTimeIsShared() {
        #expect(feed("Work Mac").label == "Work Mac")
        #expect(feed("Work Mac", level: .busy).label == "Work Mac, busy time only")
    }

    @Test func choosingFromWhatWasRead() async throws {
        let snapshot = try await snapshot()
        let mine = feed("mine", minutesAgo: 10), theirs = feed("theirs", shared: true)
        let found = [(mine, snapshot), (theirs, snapshot)]
        guard case .snapshot(let shown) = try CloudKitReader.choose(found, zoneCount: 2, needsNewerApp: false, preferred: nil) else {
            Issue.record("nothing chosen"); return
        }
        #expect(shown.feed == mine && shown.feeds.map(\.id) == ["mine", "theirs"])
        guard case .snapshot(let other) = try CloudKitReader.choose(found, zoneCount: 2, needsNewerApp: false, preferred: "theirs") else {
            Issue.record("nothing chosen"); return
        }
        #expect(other.feed == theirs)
    }

    @Test func emptyAndUnreadableCases() throws {
        #expect(try CloudKitReader.choose([], zoneCount: 0, needsNewerApp: false, preferred: nil) == .sharingOff)
        #expect(try CloudKitReader.choose([], zoneCount: 2, needsNewerApp: false, preferred: nil) == .nothingPublished)
        #expect(throws: ReaderError.needsNewerApp) {
            try CloudKitReader.choose([], zoneCount: 1, needsNewerApp: true, preferred: nil)
        }
    }

    @Test func aSavedCopyWithoutFeedsStillLoads() async throws {
        var snapshot = try await snapshot()
        snapshot.feed = feed("x")
        let encoder = JSONEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object["feed"] = nil
        object["feeds"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: old)
        #expect(decoded.feed == nil && decoded.feeds.isEmpty)
    }

    @Test func selectingAFeedIsRemembered() async {
        let defaults = UserDefaults(suiteName: "feed-tests-\(UUID())")!
        let selection = FeedSelection(defaults: defaults)
        let cache = SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        let store = SnapshotStore(reader: FixtureReader(now: now), cache: cache, selection: selection)
        await store.select(feed("theirs", shared: true))
        #expect(selection.preferred == "theirs")
    }
}
