import AppKit
import CalopodSync
import SwiftUI
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

/// Overview with synthetic data (example.com only), laid out at a given window size.
@MainActor
struct OverviewRig {
    let navigation = AppNavigation(environment: [:])
    let service = ServiceModel(refreshing: false)
    let inbox: InboxModel
    let schedule: CalendarModel
    let availability: AvailabilityModel
    /// Mid-day today, so the screen never depends on the real time of day.
    let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    static func make(attention: Bool = false) async throws -> OverviewRig {
        let rig = try OverviewRig(attention: attention)
        await rig.inbox.reload()
        await rig.schedule.reload()
        await rig.availability.reload()
        return rig
    }

    private init(attention: Bool) throws {
        service.status = AgentControlStatus(
            state: "ok", message: "Automatic sync checks passed.", installed: true, enabled: true, paused: false,
            running: true, intervalSeconds: 600, lastSuccessAgeSeconds: 240, failureCategory: nil, failureAgeSeconds: nil,
            usesBundledService: true, sourceLoaded: false)
        service.recentRuns = (0..<RunMark.barCount).map { $0 % 7 == 3 ? .failed : .good }
        service.overview = AgentControlOverview(
            connections: [
                .init(id: "g", provider: "google", label: "alex@example.com", isEnabled: true, selectedCalendarCount: 3),
                .init(id: "m", provider: "eventkit", label: "This Mac", isEnabled: true, selectedCalendarCount: 2),
            ], arms: [.init(id: "a1", name: "Main", sourceCount: 3, isEnabled: true)])
        if attention {
            service.health = HealthReport(status: "attention", message: "x", checks: [
                .init(name: "calendar-permission", state: "failed", reason: "not-granted"),
                .init(name: "schedule", state: "pending", reason: "paused"),
            ], warnings: ["Give Calopod full Calendar access in System Settings."])
        }
        inbox = InboxModel(service: try MacFixture(count: 3, overlapping: true).inbox)

        // Soon after the fixed time of day, so they are still ahead when Overview reads the day.
        let start = noon.addingTimeInterval(120)
        let calendars = (1...6).map {
            ScheduleCalendar(id: "c\($0)", name: "Calendar \($0)", account: "alex@example.com", provider: "google")
        }
        let events = (0..<5).map { index in
            ScheduleEvent(
                id: "e\(index)", calendarID: "c1", title: "Meeting \(index + 1)",
                startsAt: start.addingTimeInterval(Double(index) * 360), endsAt: start.addingTimeInterval(Double(index) * 360 + 300))
        }
        let current = CalendarSchedule(calendars: calendars, events: events)
        schedule = CalendarModel(
            defaults: UserDefaults(suiteName: "overview-fit-\(UUID().uuidString)")!, aliases: .isolated(), load: { current })
        availability = AvailabilityModel(now: { [noon] in noon }, load: { days in
            days.map { day in
                let range = DateInterval(start: day, duration: 86_400)
                let busy = AvailabilityInterval(kind: .busy, start: day.addingTimeInterval(36_000), end: day.addingTimeInterval(43_200))
                let free = AvailabilityInterval(kind: .free, start: day.addingTimeInterval(32_400), end: day.addingTimeInterval(36_000))
                let after = OutsideInterval(side: .after, start: day.addingTimeInterval(64_800), end: day.addingTimeInterval(70_200))
                let result = AvailabilityResult(
                    busy: [busy], free: [free], workingWindows: [DateInterval(start: day.addingTimeInterval(32_400), end: day.addingTimeInterval(61_200))],
                    outside: [after])
                return AvailabilityDayReport(day: range, result: result, summary: AvailabilityDay(result, day: range))
            }
        })
    }

    /// The panel Overview sits in for a window of this size.
    static func panel(window: CGSize) -> CGSize {
        CGSize(width: window.width - Sidebar.width - Sidebar.inset * 3, height: window.height - Sidebar.inset * 2)
    }

    func view(collapsed: Bool = false) -> some View {
        OverviewScreen(
            model: service, navigation: navigation,
            setup: SetupModel(aliases: .isolated(), colors: .isolated()), now: { [noon] in noon })
            .environment(inbox)
            .environment(schedule)
            .environment(CalendarAccessModel())
            .environment(availability)
            .environment(OverviewRefresh(steps: []))
            .environment(\.sidebarCollapsed, collapsed)
            .appTypography()
    }
}

@MainActor
final class OverviewFitTests: XCTestCase {
    private let defaultWindow = CGSize(width: 1140, height: 700)

    private let minimumWindow = CGSize(width: 860, height: 580)

    /// The lowest row of the rendered panel that has any card drawn on it. The panel is transparent, so
    /// empty space has no alpha. A scrolling page paints right to the bottom edge.
    private func contentBottom(_ rig: OverviewRig, panel: CGSize) -> CGFloat {
        let host = NSHostingView(rootView: rig.view().frame(width: panel.width, height: panel.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: panel)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / panel.height
        for row in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for column in stride(from: 0, to: rep.pixelsWide, by: 4) where (rep.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.05 {
                return CGFloat(row + 1) / scale
            }
        }
        return 0
    }

    /// Overview must end above the page's bottom margin at the default and the minimum window size, so
    /// it never scrolls, and at the default size it uses most of the height.
    func testOverviewFitsAndFillsTheWindow() async throws {
        setenv("CALOPOD_STATE_PATH", NSTemporaryDirectory() + "calopod-overview-fit-\(UUID().uuidString)", 1)
        let rig = try await OverviewRig.make()
        for (window, fill) in [(defaultWindow, 0.8), (minimumWindow, 0.8)] {
            let panel = OverviewRig.panel(window: window)
            let bottom = contentBottom(rig, panel: panel)
            XCTAssertLessThanOrEqual(bottom, panel.height - Theme.Page.bottom + 2, "\(window)")
            XCTAssertGreaterThanOrEqual(bottom, panel.height * fill, "\(window)")
        }
    }

    func testAvailabilityOpensInCalendarAndAnEventOpensTheSchedule() async throws {
        let rig = try await OverviewRig.make()
        XCTAssertEqual(rig.navigation.calendarPage, .schedule)
        rig.navigation.openAvailability()
        XCTAssertEqual(rig.navigation.selection, .calendar)
        XCTAssertEqual(rig.navigation.calendarPage, .availability)

        let event = try XCTUnwrap(rig.schedule.schedule?.events.first)
        rig.navigation.openCalendar(showing: event, in: rig.schedule)
        XCTAssertEqual(rig.navigation.selection, .calendar)
        XCTAssertEqual(rig.navigation.calendarPage, .schedule)
    }
}
