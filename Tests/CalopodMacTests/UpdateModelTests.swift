import CalopodProviders
import Foundation
import XCTest

@testable import CalopodMac

@MainActor
final class UpdateModelTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        var count = 0
        var result = UpdateResult.available(version: "1.0.2", page: URL(string: "https://github.com/ElijahQatana/calopod/releases/tag/v1.0.2")!)
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private let calls = Calls()
    private let suite = UserDefaults(suiteName: "calopod.tests.\(UUID().uuidString)")!

    private func make() -> UpdateModel {
        let calls = calls
        return UpdateModel(defaults: suite, current: "1.0.1", lookup: { _ in
            calls.count += 1
            return calls.result
        }, now: { self.clock })
    }

    func testNothingIsAskedUnlessTheDailyCheckIsOn() async {
        let model = make()
        await model.checkIfDue()
        XCTAssertEqual(calls.count, 0)
        await model.check()
        XCTAssertEqual(calls.count, 1)
    }

    func testTheDailyCheckRunsOncePerDay() async {
        let model = make()
        model.setChecksDaily(true)
        await model.checkIfDue()
        await model.checkIfDue()
        XCTAssertEqual(calls.count, 1)
        clock += 86_400 + 1
        await model.checkIfDue()
        XCTAssertEqual(calls.count, 2)
    }

    func testTheChoiceIsKept() {
        make().setChecksDaily(true)
        XCTAssertTrue(make().checksDaily)
    }

    func testClosingTheNoteHidesThatVersionOnly() async {
        let model = make()
        await model.check()
        XCTAssertEqual(model.offered?.version, "1.0.2")
        model.dismiss()
        XCTAssertNil(model.offered)
        XCTAssertNil(make().offered)
        XCTAssertEqual(make().dismissed, "1.0.2")
        calls.result = .available(version: "1.0.3", page: URL(string: "https://github.com/ElijahQatana/calopod/releases/tag/v1.0.3")!)
        await model.check()
        XCTAssertEqual(model.offered?.version, "1.0.3")
    }
}
