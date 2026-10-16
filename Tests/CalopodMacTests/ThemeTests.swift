import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

final class ThemeTests: XCTestCase {
    private func hex(_ color: Color, _ name: NSAppearance.Name) throws -> String {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result = ""
        appearance.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            result = String(
                format: "%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        return result
    }

    func testAccentResolvesPerAppearance() throws {
        XCTAssertEqual(try hex(Theme.accent, .aqua), "b45309")
        XCTAssertEqual(try hex(Theme.accent, .darkAqua), "f5a623")
    }

    func testOnAccentDiffersPerAppearance() throws {
        XCTAssertEqual(try hex(Theme.onAccent, .aqua), "ffffff")
        XCTAssertNotEqual(try hex(Theme.onAccent, .darkAqua), "ffffff")
    }

    private func alpha(_ color: Color, _ name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)!.alphaComponent
        }
        return result
    }

    func testFrameIsMoreSeeThroughThanSidebarThanContent() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let frame = try alpha(Theme.frameTint, name)
            let sidebar = [try alpha(Theme.sidebarFill, name), try alpha(Theme.sidebarSheen, name)]
            let content = try alpha(Theme.contentFill, name)
            XCTAssertLessThan(frame, sidebar.min()!)
            XCTAssertLessThan(sidebar.max()!, content)
        }
    }

    func testFrameTintStaysThinSoTheDesktopCarries() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertLessThanOrEqual(try alpha(Theme.frameTint, name), 0.15)
        }
    }
}
