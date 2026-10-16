import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class InboxNavigationTests: XCTestCase {
    func testOpeningInboxSetsTheFilter() {
        let navigation = AppNavigation(environment: [:])
        navigation.openInbox(.maybe)
        XCTAssertEqual(navigation.selection, .inbox)
        XCTAssertEqual(navigation.inboxFilter, .maybe)
        navigation.openInbox()
        XCTAssertEqual(navigation.inboxFilter, .all)
    }
}
