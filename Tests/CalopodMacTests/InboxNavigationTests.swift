import Foundation
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class InboxNavigationTests: XCTestCase {
    func testOpeningInboxSetsTheFilter() {
        let navigation = AppNavigation(environment: [:])
        navigation.openInbox(.maybe)
        XCTAssertEqual(navigation.selection, .inbox)
        XCTAssertEqual(navigation.inboxFilter, .maybe)
        navigation.openInbox()
        XCTAssertEqual(navigation.inboxFilter, .all)
    }

    private func event(
        response: ScheduleResponse = .accepted, change: ScheduleChange = .none, overlaps: [String] = []
    ) -> ScheduleEvent {
        ScheduleEvent(
            id: "e1", calendarID: "work", title: "Sync", startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_003_600), response: response, overlaps: overlaps, change: change)
    }

    func testOpeningAnEventPicksAFilterThatHoldsIt() {
        let cases: [(ScheduleEvent, InboxFilter)] = [
            (event(response: .needsResponse), .needsRSVP),
            (event(response: .tentative), .maybe),
            (event(change: .changed), .changed),
            (event(change: .uncertain), .changed),
            (event(overlaps: ["Standup"]), .conflicts),
            (event(response: .needsResponse, change: .changed, overlaps: ["Standup"]), .needsRSVP),
            (event(), .all),
        ]
        for (event, filter) in cases {
            let navigation = AppNavigation(environment: [:])
            navigation.openInbox(showing: event)
            XCTAssertEqual(navigation.inboxFilter, filter)
            XCTAssertEqual(navigation.inboxEvent, "e1")
            XCTAssertEqual(navigation.selection, .inbox)
        }
    }

    func testTheRequestedEventIsTakenOnceAndOnlyIfListed() {
        let navigation = AppNavigation(environment: [:])
        let entry = InboxEntry(
            id: "e1", revisionID: "e1:1", title: "Sync", startsAt: .now, endsAt: .now, isAllDay: false,
            calendarID: "work", calendarName: "Work", organizer: nil, location: nil, response: .needsResponse,
            reasons: [.needsResponse], changeIsUncertain: false, overlapCount: 0)
        navigation.openInbox(showing: event(response: .needsResponse))
        XCTAssertNil(navigation.takeInboxEvent(in: []))
        XCTAssertNil(navigation.inboxEvent)
        navigation.openInbox(showing: event(response: .needsResponse))
        XCTAssertEqual(navigation.takeInboxEvent(in: [entry]), "e1")
        XCTAssertNil(navigation.takeInboxEvent(in: [entry]))
    }
}
