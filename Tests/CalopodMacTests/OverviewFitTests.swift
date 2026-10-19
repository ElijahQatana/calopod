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
        service.recentRuns = (0..<20).map { $0 % 7 == 3 ? .failed : .good }
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

        // Soon after now, so they are still ahead when Overview reads the day.
        let start = Date().addingTimeInterval(120)
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
        availability = AvailabilityModel(load: { days in
            days.map { day in
                let range = DateInterval(start: day, duration: 86_400)
                let busy = AvailabilityInterval(kind: .busy, start: day.addingTimeInterval(36_000), end: day.addingTimeInterval(43_200))
                let free = AvailabilityInterval(kind: .free, start: day.addingTimeInterval(32_400), end: day.addingTimeInterval(36_000))
                let result = AvailabilityResult(
                    busy: [busy], free: [free], workingWindows: [DateInterval(start: day.addingTimeInterval(32_400), end: day.addingTimeInterval(61_200))])
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
            setup: SetupModel(aliases: .isolated(), colors: .isolated()))
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

    /// Everything on Overview at its natural size must fit the panel at the default window size.
    func testEverythingFitsTheDefaultWindowWithoutScrolling() async throws {
        setenv("CALOPOD_STATE_PATH", NSTemporaryDirectory() + "calopod-overview-fit-\(UUID().uuidString)", 1)
        let rig = try await OverviewRig.make()
        let panel = OverviewRig.panel(window: defaultWindow)
        let host = NSHostingView(rootView: rig.view().frame(width: panel.width))
        XCTAssertLessThanOrEqual(host.fittingSize.height, panel.height)
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
