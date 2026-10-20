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

    /// The box around everything drawn in a region, in pixels.
    private func inkBounds(_ rep: NSBitmapImageRep, _ region: CGRect, scale: CGFloat) -> CGRect {
        var box = CGRect.null
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.05, c.redComponent + c.greenComponent + c.blueComponent < 2.9 {
                    box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return box
    }

    /// Switching pages must not move or resize the page switch, or move or restyle the Today pill and arrows.
    func testScheduleAndAvailabilityShareTheirControls() async throws {
        setenv("CALOPOD_STATE_PATH", NSTemporaryDirectory() + "calopod-header-\(UUID().uuidString)", 1)
        let rig = try await OverviewRig.make()
        for window in [CGSize(width: 1140, height: 700), CGSize(width: 860, height: 580)] {
            for collapsed in [false, true] {
                let panel = OverviewRig.panel(window: window)
                let schedule = render(rig, page: .schedule, collapsed: collapsed, panel: panel)
                let availability = render(rig, page: .availability, collapsed: collapsed, panel: panel)
                let scale = CGFloat(schedule.pixelsWide) / panel.width
                let label = "\(window) collapsed \(collapsed)"

                // The switch's track is the same size and place whichever page is selected.
                let row = CGRect(x: 0, y: 62, width: 190, height: 40)
                let track = inkBounds(schedule, row, scale: scale)
                XCTAssertFalse(track.isNull, label)
                XCTAssertEqual(track, inkBounds(availability, row, scale: scale), label)

                // Today and the arrows hold no selection, so they match pixel for pixel.
                let right = CGRect(x: panel.width - 170, y: 0, width: 170, height: 56)
                XCTAssertFalse(inkBounds(schedule, CGRect(x: right.minX, y: right.minY, width: right.width, height: right.height), scale: scale).isNull, label)
                var differing = 0
                for y in Int(right.minY * scale)..<Int(right.maxY * scale) {
                    for x in Int(right.minX * scale)..<Int(right.maxX * scale) where schedule.colorAt(x: x, y: y) != availability.colorAt(x: x, y: y) {
                        differing += 1
                    }
                }
                XCTAssertEqual(differing, 0, label)
            }
        }
    }
}
