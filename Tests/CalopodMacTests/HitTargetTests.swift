import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

/// Hit testing needs a live window, so these check the size rule and the laid-out size of each shared style.
@MainActor
final class HitTargetTests: XCTestCase {
    func testSizeGrowsToMinimumOnly() {
        XCTAssertEqual(HitTarget.size(of: CGSize(width: 10, height: 12)), CGSize(width: 28, height: 28))
        XCTAssertEqual(HitTarget.size(of: CGSize(width: 90, height: 36)), CGSize(width: 90, height: 36))
        XCTAssertEqual(HitTarget.size(of: CGSize(width: 14, height: 40)), CGSize(width: 28, height: 40))
    }

    private func size<S: ButtonStyle>(_ style: S, label: String = "Go") -> CGSize {
        let host = NSHostingView(rootView: Button {} label: { Text(label) }.buttonStyle(style))
        return host.fittingSize
    }

    func testTextButtonsAreAtLeastControlHeight() {
        for (name, fitted) in [
            ("accent", size(AccentButtonStyle())), ("neutral", size(SecondaryButtonStyle())),
            ("quiet", size(QuietButtonStyle())),
        ] {
            XCTAssertGreaterThanOrEqual(fitted.height, Theme.Control.height, name)
            XCTAssertGreaterThanOrEqual(fitted.width, 28, name)
        }
        XCTAssertGreaterThanOrEqual(size(RowButtonStyle()).height, HitTarget.minimum)
    }

    func testIconButtonsAreAtLeastMinimumSquare() {
        let circle = size(CircleToolbarButtonStyle(), label: "x")
        XCTAssertGreaterThanOrEqual(min(circle.width, circle.height), HitTarget.minimum)
        let host = NSHostingView(rootView: Button {} label: { Image(systemName: "xmark") }.buttonStyle(BareButtonStyle()))
        XCTAssertGreaterThanOrEqual(min(host.fittingSize.width, host.fittingSize.height), HitTarget.minimum)
    }
}
