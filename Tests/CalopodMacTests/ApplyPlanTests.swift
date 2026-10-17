import XCTest

@testable import CalopodMac

final class ApplyPlanTests: XCTestCase {
    func testSamePlanIgnoresOrder() {
        XCTAssertTrue(ServiceModel.samePlan(["1|create", "2|remove"], ["2|remove", "1|create"]))
    }

    func testAChangedOrExtraChangeIsADifferentPlan() {
        XCTAssertFalse(ServiceModel.samePlan(["1|create"], ["1|remove"]))
        XCTAssertFalse(ServiceModel.samePlan(["1|create"], ["1|create", "2|remove"]))
    }
}
