import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

@MainActor
final class PageFitTests: XCTestCase {
    private func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        return host.fittingSize.height
    }

    private func card(_ height: CGFloat) -> some View { Color.gray.frame(height: height) }

    func testCardsShareARowHeightWhenSideBySideAndKeepTheirOwnWhenStacked() {
        let pair = CardColumns(minColumnWidth: 300, spacing: 16) { card(40); card(100) }
        XCTAssertEqual(height(pair, width: 700), 100)
        XCTAssertEqual(height(pair, width: 400), 40 + 16 + 100)
    }

    func testCardsWrapIntoRowsWhenThereAreMoreThanFit() {
        let three = CardColumns(minColumnWidth: 300, spacing: 16) { card(40); card(60); card(80) }
        XCTAssertEqual(height(three, width: 700), 60 + 16 + 80)
    }

    func testGapsStartAtTheirNaturalSpacing() {
        let stack = SpreadStack(spacing: 10, maxSpacing: 20) { card(50); card(50); card(50) }
        XCTAssertEqual(height(stack, width: 300), 170)
    }
}
