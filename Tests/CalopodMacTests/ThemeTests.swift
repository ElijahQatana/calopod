import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

@MainActor
final class ThemeTests: XCTestCase {
    private func rgb(_ color: Color, _ name: NSAppearance.Name) throws -> [CGFloat] {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            result = [c.redComponent, c.greenComponent, c.blueComponent]
        }
        return result
    }

    func testTokensThatFlipPickADifferentColorInDarkMode() throws {
        let tokens: [(String, Color)] = [
            ("accent", Theme.accent), ("onAccent", Theme.onAccent), ("pane", Theme.pane), ("group", Theme.group),
            ("goodText", Theme.goodText), ("cautionText", Theme.cautionText), ("badText", Theme.badText),
        ]
        for (name, color) in tokens {
            XCTAssertNotEqual(try rgb(color, .aqua), try rgb(color, .darkAqua), name)
        }
    }

    func testPaneIsLightInLightModeAndDarkInDarkMode() throws {
        XCTAssertGreaterThan(try rgb(Theme.pane, .aqua).reduce(0, +), 2.5)
        XCTAssertLessThan(try rgb(Theme.pane, .darkAqua).reduce(0, +), 0.5)
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
            XCTAssertLessThan(content, try alpha(Theme.innerFill, name))
        }
    }

    func testFrameTintStaysThinSoTheDesktopCarries() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertLessThanOrEqual(try alpha(Theme.frameTint, name), 0.15)
        }
    }
}
