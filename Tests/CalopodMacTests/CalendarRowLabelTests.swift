import XCTest

@testable import CalopodMac

final class CalendarRowLabelTests: XCTestCase {
    func testRowActionsNameTheCalendar() {
        XCTAssertEqual(CalendarRow.renameLabel("Home"), "Rename Home")
        XCTAssertEqual(CalendarRow.ignoreLabel("Home", ignored: false), "Ignore Home")
        XCTAssertEqual(CalendarRow.ignoreLabel("Home", ignored: true), "Stop ignoring Home")
    }
}
