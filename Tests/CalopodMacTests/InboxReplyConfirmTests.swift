import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class InboxReplyConfirmTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var all: [String] { lock.withLock { items } }
        func add(_ item: String) { lock.withLock { items.append(item) } }
    }

    private struct NoRead: Error {}

    private func model(_ sent: Sent) -> InboxModel {
        let model = InboxModel(
            send: { id, choice in
                sent.add("\(id):\(choice)")
                return InboxReplyResult(status: .confirmed, message: "Sent.")
            },
            afterSend: {},
            readDetail: { _ in throw NoRead() })
        model.selection = "event-1"
        return model
    }

    func testClickingAReplyOnlyAsks() async {
        let sent = Sent()
        let model = model(sent)
        model.askToReply(.yes)
        XCTAssertEqual(model.pendingReply, .yes)
        XCTAssertEqual(sent.all, [])
        XCTAssertNil(model.result)
    }

    func testCancelSendsNothing() async {
        let sent = Sent()
        let model = model(sent)
        model.askToReply(.no)
        model.cancelReply()
        await model.confirmReply()
        XCTAssertNil(model.pendingReply)
        XCTAssertEqual(sent.all, [])
    }

    func testConfirmSendsOnceAndOnlyTheAskedAnswer() async {
        let sent = Sent()
        let model = model(sent)
        model.askToReply(.maybe)
        await model.confirmReply()
        await model.confirmReply()
        XCTAssertEqual(sent.all, ["event-1:maybe"])
        XCTAssertEqual(model.result?.status, .confirmed)
    }

    func testChangingTheSelectionDropsTheQuestion() async {
        let sent = Sent()
        let model = model(sent)
        model.askToReply(.yes)
        model.selection = "event-2"
        XCTAssertNil(model.pendingReply)
        XCTAssertEqual(sent.all, [])
    }

    func testHoldIsNotAReply() {
        let model = model(Sent())
        model.askToReply(.noChange)
        XCTAssertNil(model.pendingReply)
    }
}
