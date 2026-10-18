import Foundation
import XCTest

@testable import CalopodMac

@MainActor
final class SetupNoticeTests: XCTestCase {
    private var saved: [String: String?] = [:]

    override func setUp() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (key, value) in [
            ("CALOPOD_STATE_PATH", root.appendingPathComponent("state.sqlite").path),
            ("CALOPOD_GOOGLE_CLIENT_ID", nil), ("CALOPOD_MICROSOFT_CLIENT_ID", nil),
        ] {
            saved[key] = ProcessInfo.processInfo.environment[key]
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    func testMissingClientIDShowsHelpAndCanBeDismissed() async throws {
        let model = SetupModel()
        await model.connect(.google)
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("Google sign-in has no client ID"))
        model.dismissNotice()
        XCTAssertNil(model.notice)

        await model.connect(.microsoft)
        XCTAssertTrue(try XCTUnwrap(model.notice).contains("Microsoft sign-in has no client ID"))
    }

    func testStartingAnotherActionClearsThePreviousError() async {
        let model = SetupModel()
        await model.connect(.google)
        let google = model.notice
        await model.connect(.microsoft)
        XCTAssertNotNil(model.notice)
        XCTAssertNotEqual(model.notice, google)
    }
}
