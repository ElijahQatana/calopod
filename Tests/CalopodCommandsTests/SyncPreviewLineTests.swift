import CalopodDomain
import CalopodStore
import XCTest

@testable import CalopodCommands

final class SyncPreviewLineTests: XCTestCase {
    private func item(_ action: SyncPlanAction, payload: DesiredEventPayload? = nil) -> SyncPlanItem {
        SyncPlanItem(
            id: "item", armID: "arm", mirrorKey: "mirror", sourceKeyHash: "source", action: action,
            reason: .sourceMissing, desiredFingerprint: nil, payload: payload)
    }

    private let arm = StoredArm(
        id: "arm", configurationID: "config", sourceBindingIDs: ["work"], targetBindingID: "main", ruleMode: .busy)

    func testLineTakesTitleAndTimeFromTheSourceEvent() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = DesiredEventPayload(
            startsAt: start, endsAt: start.addingTimeInterval(60), isAllDay: false, availability: "busy",
            title: "Busy", isPrivate: nil)
        let line = SyncPreview.Line.make(item: item(.update, payload: payload), arm: arm, armName: "Main", source: nil)
        XCTAssertEqual(line.title, "Busy")
        XCTAssertEqual(line.startsAt, start)
        XCTAssertEqual(line.targetCalendarID, "main")
    }

    func testRemovalWithNoSourceKeepsTheTargetOnly() {
        let line = SyncPreview.Line.make(item: item(.remove), arm: arm, armName: "Main", source: nil)
        XCTAssertNil(line.title)
        XCTAssertNil(line.startsAt)
        XCTAssertNil(line.sourceCalendarID)
        XCTAssertEqual(line.action, "remove")
    }
}
