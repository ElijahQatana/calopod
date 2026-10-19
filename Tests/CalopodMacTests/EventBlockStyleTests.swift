import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class EventBlockStyleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func copy(_ mode: ScheduleCopyMode, _ response: ScheduleResponse) -> ScheduleEvent {
        ScheduleEvent(
            id: "copy:b:a", calendarID: "b", title: mode == .busy ? "Busy" : "Planning", startsAt: start,
            endsAt: start.addingTimeInterval(1800), response: .none,
            copyOrigin: ScheduleCopyOrigin(
                mode: mode, armName: "Team", sourceEventID: "a", sourceCalendarID: "a-cal",
                sourceCalendarName: "Work", sourceResponse: response))
    }

    private func plain(_ response: ScheduleResponse) -> ScheduleEvent {
        ScheduleEvent(id: "a", calendarID: "a-cal", title: "Planning", startsAt: start, endsAt: start.addingTimeInterval(1800), response: response)
    }

    func testStyleByCopyModeAndResponse() {
        typealias Style = EventBlockStyle
        let cases: [(ScheduleEvent, Style.Base, hatched: Bool, faded: Bool)] = [
            (copy(.fullDetails, .accepted), .copyFull, false, false),
            (copy(.busy, .accepted), .copyBusy, false, false),
            (copy(.fullDetails, .declined), .copyFull, true, false),
            (copy(.busy, .declined), .copyBusy, false, false),
            (plain(.declined), .plain, true, true),
            (plain(.tentative), .plain, false, false),
            (plain(.accepted), .plain, false, false),
            (plain(.needsResponse), .needsRSVP, false, false),
        ]
        for (event, base, hatched, faded) in cases {
            let style = Style.of(event)
            XCTAssertEqual([style.base == base, style.hatched == hatched, style.faded == faded], [true, true, true], "\(event.id) \(event.carriedResponse)")
        }
        // A copy that predates the origin record is drawn as a quiet Busy block.
        XCTAssertEqual(Style.of(isCopy: true, copyMode: nil, response: .declined).base, .copyBusy)
    }

    func testChipTextNamesTheKindAndTheCarriedAnswer() {
        let cases: [(ScheduleCopyMode, ScheduleResponse, String)] = [
            (.fullDetails, .accepted, "Full details copy · Accepted"),
            (.busy, .tentative, "Busy copy · Maybe"),
            (.fullDetails, .declined, "Full details copy · Declined"),
            (.busy, .none, "Busy copy"),
        ]
        for (mode, response, text) in cases { XCTAssertEqual(CopyWords.chip(copy(mode, response)), text) }
        XCTAssertTrue(CopyWords.replyHint(copy(.busy, .accepted)).contains("only shows that you are busy"))
        XCTAssertTrue(CopyWords.replyHint(copy(.fullDetails, .accepted)).contains("Reply on the original"))
        XCTAssertEqual(CopyWords.provenance(try! XCTUnwrap(copy(.busy, .none).copyOrigin), calendarName: "Work"), "Copied from Work by Team")
    }

    func testShowOriginalNeedsTheSourceInTheSchedule() async throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "EventBlockStyleTests"))
        suite.removePersistentDomain(forName: "EventBlockStyleTests")
        let copied = copy(.fullDetails, .accepted)
        let schedule = CalendarSchedule(calendars: [], events: [plain(.accepted), copied])
        let model = CalendarModel(now: { self.start }, defaults: suite, aliases: .isolated(), load: { schedule })
        await model.reload()
        XCTAssertEqual(model.original(of: copied)?.id, "a")
        model.show(try XCTUnwrap(model.original(of: copied)))
        XCTAssertEqual(model.selectedID, "a")

        let loose = CalendarModel(now: { self.start }, defaults: suite, aliases: .isolated(), load: { CalendarSchedule(calendars: [], events: [copied]) })
        await loose.reload()
        XCTAssertNil(loose.original(of: copied))
    }
}
