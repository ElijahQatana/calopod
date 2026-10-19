import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class SyncReviewTests: XCTestCase {
    private func line(_ id: String, _ action: String, title: String? = "Standup", source: String? = "work") -> SyncPreview.Line {
        SyncPreview.Line(
            id: id, armName: "Main", action: action, reason: "Target copy is out of date", title: title,
            startsAt: title == nil ? nil : Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: title == nil ? nil : Date(timeIntervalSince1970: 1_800_003_600),
            sourceCalendarID: source, targetCalendarID: "main")
    }

    private let names = ["work": "Work", "main": "Main"]

    func testRemovalsComeFirstAndKeepTheirOrder() {
        let lines = [line("a", "update"), line("b", "remove"), line("c", "create"), line("d", "remove")]
        XCTAssertEqual(SyncReviewSection.ordered(lines).map(\.id), ["b", "d", "a", "c"])
    }

    func testRemovalsAreLabeledApartFromUpdates() {
        XCTAssertEqual(SyncReviewSection.label("remove"), "Remove")
        XCTAssertEqual(SyncReviewSection.label("update"), "Update")
    }

    func testDetailNamesSourceAndTarget() {
        let text = SyncReviewSection.detail(line("a", "update"), calendarName: { names[$0] })
        XCTAssertTrue(text.contains("Work to Main"))
        XCTAssertTrue(text.hasSuffix("Target copy is out of date"))
    }

    func testCopyWithNoKnownSourceNamesTheCopyAndHasNoTime() {
        let text = SyncReviewSection.detail(line("a", "remove", title: nil, source: nil), calendarName: { names[$0] })
        XCTAssertEqual(text, "copy on Main · Target copy is out of date")
    }

    func testUncheckedLinesBlockApplyAndAreNotRepairs() {
        let unchecked = SyncPreview.Line(
            id: "u", armName: "Main", action: "repair", reason: "Target calendar could not be fully read",
            title: "Standup", startsAt: Date(timeIntervalSince1970: 1_800_000_000), targetCalendarID: "main", isUnchecked: true)
        let preview = SyncPreview(unchecked: 276, lines: [unchecked])
        XCTAssertFalse(preview.canApply)
        XCTAssertEqual(preview.changeCount, 276)
        XCTAssertEqual(SyncReviewSection.summaryLine(preview), "276 could not be checked")
        XCTAssertEqual(SyncReviewSection.label(unchecked), "Not checked")
        XCTAssertFalse(SyncReviewSection.detail(unchecked, calendarName: { names[$0] }).contains("could not be fully read"))
        XCTAssertTrue(SyncPreview(repairs: 1).canApply)
    }
}
