import AppKit
import SwiftUI
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class CalendarHeaderTests: XCTestCase {
    private func render(_ rig: OverviewRig, page: CalendarPage, collapsed: Bool, panel: CGSize) -> NSBitmapImageRep {
        rig.navigation.calendarPage = page
        let view = CalendarScreen(navigation: rig.navigation)
            .environment(rig.schedule).environment(rig.availability)
            .environment(\.sidebarCollapsed, collapsed).appTypography()
            .frame(width: panel.width, height: panel.height).background(Color.white)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: panel)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Switching pages must not move or restyle the page switch or the Today and arrow buttons.
    func testScheduleAndAvailabilityShareTheirControls() async throws {
        setenv("CALOPOD_STATE_PATH", NSTemporaryDirectory() + "calopod-header-\(UUID().uuidString)", 1)
        let rig = try await OverviewRig.make()
        for window in [CGSize(width: 1140, height: 700), CGSize(width: 860, height: 580)] {
            for collapsed in [false, true] {
                let panel = OverviewRig.panel(window: window)
                let schedule = render(rig, page: .schedule, collapsed: collapsed, panel: panel)
                let availability = render(rig, page: .availability, collapsed: collapsed, panel: panel)
                let scale = CGFloat(schedule.pixelsWide) / panel.width
                // The page switch row, and the Today pill and arrows at the top right.
                let regions = [
                    CGRect(x: 0, y: 62, width: 190, height: 40), CGRect(x: panel.width - 170, y: 0, width: 170, height: 56),
                ]
                for region in regions {
                    for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
                        for x in stride(from: Int(region.minX * scale), to: Int(region.maxX * scale), by: 2) {
                            XCTAssertEqual(schedule.colorAt(x: x, y: y), availability.colorAt(x: x, y: y), "\(window) \(collapsed) \(x),\(y)")
                            if schedule.colorAt(x: x, y: y) != availability.colorAt(x: x, y: y) { return }
                        }
                    }
                }
            }
        }
    }
}
