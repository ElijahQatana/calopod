import CalopodSync
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class InboxModelFlowTests: XCTestCase {
    private func loaded(_ f: MacFixture) async -> InboxModel {
        let model = InboxModel(service: f.inbox)
        await model.reload()
        return model
    }

    func testSelectionFollowsTheVisibleListAndHoldWraps() async throws {
        let f = try MacFixture(count: 3)
        let model = await loaded(f)
        let entries = try XCTUnwrap(model.board).entries
        XCTAssertEqual(entries.count, 3)

        model.ensureSelection(in: entries)
        XCTAssertEqual(model.selection, entries[0].id)
        model.selection = "gone"
        model.ensureSelection(in: entries)
        XCTAssertEqual(model.selection, entries[0].id)

        model.hold(in: entries)
        XCTAssertEqual(model.selection, entries[1].id)
        model.hold(in: entries)
        model.hold(in: entries)
        XCTAssertEqual(model.selection, entries[0].id)
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testAReloadDropsAnEventThatLeftTheList() async throws {
        let f = try MacFixture(count: 2)
        let model = await loaded(f)
        model.selection = "key1"
        await model.reload()
        XCTAssertEqual(model.detail?.entry.id, "key1")

        try f.apply(keys: ["key0"])
        await model.reload()
        XCTAssertNil(model.selection)
        await Task.yield()
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.count, 1)
    }

    /// Both events were answered, then edited: each has one unread change.
    private func changedFixture() async throws -> (MacFixture, InboxModel) {
        let f = try MacFixture(count: 2)
        try f.apply(keys: ["key0", "key1"], response: .accepted)
        try f.apply(keys: ["key0", "key1"], title: "Moved", response: .accepted)
        return (f, await loaded(f))
    }

    func testAcknowledgeClearsOnlyThatChange() async throws {
        let (f, model) = try await changedFixture()
        let entries = try XCTUnwrap(model.board).entries
        XCTAssertEqual(try XCTUnwrap(model.board).count(.changed), 2)

        await model.acknowledge(entries[0])
        XCTAssertNil(model.notice)
        XCTAssertEqual(try XCTUnwrap(model.board).entries(for: .changed).map(\.id), [entries[1].id])
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testAcknowledgeIgnoresAChangeThatWasNotTheOneShown() async throws {
        let (f, model) = try await changedFixture()
        let shown = try XCTUnwrap(model.board).entries[0]

        // Edited again after the list was drawn.
        try f.apply(keys: ["key0", "key1"], title: "Moved again", response: .accepted)
        await model.acknowledge(shown)

        await model.reload()
        // The newer edit is still unread.
        let now = try XCTUnwrap(try XCTUnwrap(model.board).entries.first { $0.id == shown.id })
        XCTAssertNotEqual(now.revisionID, shown.revisionID)
        XCTAssertTrue(now.reasons.contains(.changedAfterResponse))
    }

    func testAReplyIsSentOnceAndTheAnsweredEventLeavesTheList() async throws {
        let f = try MacFixture(count: 2)
        let model = await loaded(f)
        model.selection = "key0"
        model.askToReply(.yes)
        let before = await f.remote.writes
        XCTAssertEqual(before, 0)

        await model.confirmReply()
        await model.confirmReply()
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.result?.status, .confirmed)
        XCTAssertEqual(model.board?.entries.map(\.id), ["key1"])
    }

    func testAReplyWithAnUnknownOutcomeIsNotSentAgain() async throws {
        let f = try MacFixture(count: 1)
        await f.remote.setMode(.unknown)
        let model = await loaded(f)
        model.selection = "key0"
        model.askToReply(.yes)
        await model.confirmReply()
        let first = await f.remote.writes
        XCTAssertEqual(first, 1)
        XCTAssertNotEqual(model.result?.status, .confirmed)

        model.askToReply(.yes)
        await model.confirmReply()
        let second = await f.remote.writes
        XCTAssertEqual(second, 1)
    }
}
