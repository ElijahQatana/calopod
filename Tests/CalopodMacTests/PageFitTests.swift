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

    func testCardsLayOutWhenTheProposedWidthIsNotFinite() {
        for width in [CGFloat.infinity, .nan] {
            let pair = CardColumns(minColumnWidth: 300, spacing: 16) { card(40); card(100) }
            let host = NSHostingView(rootView: AnyView(WidthProbe(width: width) { pair }))
            XCTAssertEqual(host.fittingSize.width, 300)
            XCTAssertEqual(host.fittingSize.height, 40 + 16 + 100)
        }
    }
}

/// Asks its child for a size at the given width, the way a parent probing for the maximum does.
private struct WidthProbe: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: 300, height: nil))
    }
}
