import XCTest

@testable import CalopodMac

@MainActor
final class SidebarStateTests: XCTestCase {
    func testCollapsedStateIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SidebarStateTests"))
        defaults.removePersistentDomain(forName: "SidebarStateTests")
        XCTAssertFalse(SidebarState(defaults: defaults).isCollapsed)

        SidebarState(defaults: defaults).toggle()
        XCTAssertTrue(SidebarState(defaults: defaults).isCollapsed)
    }

    func testConflictsIsNotAScreen() {
        XCTAssertNil(Screen(rawValue: "conflicts"))
        XCTAssertEqual(Screen.main + Screen.setup, Screen.allCases)
    }
}
