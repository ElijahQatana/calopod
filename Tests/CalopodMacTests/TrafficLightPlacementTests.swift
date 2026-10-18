import AppKit
import XCTest

@testable import CalopodMac

@MainActor
final class TrafficLightPlacementTests: XCTestCase {
    private let metrics = TrafficLightPlacement.Metrics(step: 20, size: CGSize(width: 14, height: 16))

    func testButtonsAreCenteredInTheRailOnOneRow() {
        let origins = TrafficLightPlacement.origins(barHeight: 52, metrics: metrics)
        let span: CGFloat = 20 * 2 + 14
        XCTAssertEqual(origins[0].x, Sidebar.inset + (Sidebar.railWidth - span) / 2)
        XCTAssertEqual(origins[1].x - origins[0].x, 20)
        XCTAssertEqual(origins[2].x - origins[1].x, 20)
        XCTAssertEqual(Set(origins.map(\.y)), [52 - (Sidebar.inset + 26) - 8])
    }

    func testOnlyTheBarHeightMovesThem() {
        let a = TrafficLightPlacement.origins(barHeight: 52, metrics: metrics)
        let b = TrafficLightPlacement.origins(barHeight: 60, metrics: metrics)
        XCTAssertEqual(a.map(\.x), b.map(\.x))
        XCTAssertEqual(b[0].y - a[0].y, 8)
    }
}
