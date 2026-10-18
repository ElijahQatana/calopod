import CalopodStore
import Foundation
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class InboxModelTests: XCTestCase {
    private struct Down: Error {}

    private final class Flag: @unchecked Sendable { var failing = true }

    private func model(_ flag: Flag) throws -> InboxModel {
        let state = LocalStateRepository(database: try .inMemory())
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString).lock")
        let service = InboxScreenService(
            makeRepository: { if flag.failing { throw Down() } else { return state } },
            makeLockURL: { lock },
            makeRefresh: { _ in { throw Down() } },
            provider: { _ in throw Down() })
        return InboxModel(service: service)
    }

    func testALoadErrorGoesAwayOnceALoadWorks() async throws {
        let flag = Flag()
        let inbox = try model(flag)
        await inbox.reload()
        XCTAssertNotNil(inbox.notice)
        XCTAssertNil(inbox.board)

        flag.failing = false
        await inbox.reload()
        XCTAssertNil(inbox.notice)
        XCTAssertEqual(inbox.board?.entries.count, 0)
    }
}
