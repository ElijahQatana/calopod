import Foundation
import XCTest

/// Screens start with PageHeader, so the large serif title is only for the setup sheet.
final class PageHeaderTests: XCTestCase {
    func testScreensUseSharedHeader() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CalopodMac")
        func text(_ name: String) throws -> String {
            try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        }
        for name in ["ArmsScreen", "InboxScreen", "CalendarScreen", "Cards"] {
            XCTAssertTrue(try text("\(name).swift").contains("PageHeader"), name)
        }
        for name in ["ArmsScreen", "InboxScreen", "CalendarScreen", "Cards", "OverviewScreen", "SettingsScreen"] {
            XCTAssertFalse(try text("\(name).swift").contains("Fonts.pageTitle"), name)
        }
    }
}
