import CalopodProviders
import Foundation
import XCTest

@testable import CalopodCommands

final class UpdateCommandTests: XCTestCase {
    func testEachResultHasPlainWords() {
        let page = URL(string: "https://github.com/ElijahQatana/calopod/releases/tag/v1.0.2")!
        let cases: [(UpdateResult, String, String)] = [
            (.upToDate, "ok", "1.0.1 is the newest"),
            (.available(version: "1.0.2", page: page), "update-available", "1.0.2 is out"),
            (.failed("Calopod couldn't reach GitHub."), "error", "couldn't reach"),
        ]
        for (result, status, words) in cases {
            let line = UpdateCheckCommand.describe(result, current: "1.0.1")
            XCTAssertEqual(line.status, status)
            XCTAssertTrue(line.message.contains(words), line.message)
        }
    }
}
