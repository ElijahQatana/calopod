import XCTest

@testable import CalopodMac

final class ReviewSheetLayoutTests: XCTestCase {
    func testSizeFollowsTheWindow() {
        XCTAssertEqual(ReviewSheetLayout.size(in: CGSize(width: 860, height: 580)), CGSize(width: 820, height: 524))
        XCTAssertEqual(ReviewSheetLayout.size(in: CGSize(width: 1000, height: 700)), CGSize(width: 960, height: 644))
    }

    func testSizeIsKeptBetweenTheLimits() {
        XCTAssertEqual(ReviewSheetLayout.size(in: CGSize(width: 1800, height: 1200)), ReviewSheetLayout.maximum)
        XCTAssertEqual(ReviewSheetLayout.size(in: CGSize(width: 500, height: 400)), ReviewSheetLayout.minimum)
    }

    func testSheetFitsInsideEveryTargetWindow() {
        for window in [CGSize(width: 860, height: 580), CGSize(width: 1000, height: 700), CGSize(width: 1100, height: 800)] {
            let size = ReviewSheetLayout.size(in: window)
            XCTAssertLessThanOrEqual(size.width, window.width - 40)
            XCTAssertLessThanOrEqual(size.height, window.height - 56)
            XCTAssertTrue(ReviewSheetLayout.isSideBySide(width: size.width))
        }
    }

    func testStacksOnlyWhenNarrow() {
        XCTAssertFalse(ReviewSheetLayout.isSideBySide(width: 759))
        XCTAssertTrue(ReviewSheetLayout.isSideBySide(width: 760))
        XCTAssertFalse(ReviewSheetLayout.isSideBySide(width: ReviewSheetLayout.minimum.width))
    }

    func testDayColumnStaysReadable() {
        XCTAssertEqual(ReviewSheetLayout.dayColumnWidth(body: 400), 300)
        XCTAssertEqual(ReviewSheetLayout.dayColumnWidth(body: 780), 327.6, accuracy: 0.01)
        XCTAssertEqual(ReviewSheetLayout.dayColumnWidth(body: 1200), 400)
    }
}
