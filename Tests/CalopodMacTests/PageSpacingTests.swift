import XCTest

@testable import CalopodMac

final class PageSpacingTests: XCTestCase {
    func testTopPadding() {
        typealias P = Theme.Page
        XCTAssertEqual(P.topPadding(collapsed: false, inlineHeader: false), P.top)
        XCTAssertEqual(P.topPadding(collapsed: false, inlineHeader: true), P.top)
        XCTAssertEqual(P.topPadding(collapsed: true, inlineHeader: false), P.belowToggle)
        XCTAssertEqual(P.topPadding(collapsed: true, inlineHeader: true), P.toggleTop)
    }

    func testTitleClearsToggleOnlyWhenCollapsed() {
        XCTAssertEqual(Theme.Page.titleInset(collapsed: false, horizontal: 28), 0)
        // The title starts after the button's right edge plus the gap, whatever the page margin.
        let toggleEnd = Theme.Page.toggleLeading + Theme.Control.circle + Theme.Page.toggleGap
        for margin in [18.0, 28.0] {
            XCTAssertEqual(Theme.Page.titleInset(collapsed: true, horizontal: margin) + margin, toggleEnd)
        }
    }

    func testTitleStart() {
        let toggleEnd = Theme.Page.toggleLeading + Theme.Control.circle + Theme.Page.toggleGap
        for margin in [18.0, 28.0] {
            XCTAssertEqual(Theme.Page.titleStart(collapsed: false, horizontal: margin), margin)
            XCTAssertEqual(Theme.Page.titleStart(collapsed: true, horizontal: margin), toggleEnd)
        }
    }
}
