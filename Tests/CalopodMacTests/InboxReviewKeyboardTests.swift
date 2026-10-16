import XCTest

@testable import CalopodMac

final class InboxReviewKeyboardTests: XCTestCase {
    func testKeysInEachMode() {
        let cases: [(ReviewKeyboard.Mode, [String], ReviewKey?)] = [
            (.card, ["y"], .reply(.yes)), (.card, ["N"], .reply(.no)), (.card, ["m"], .reply(.maybe)),
            (.card, ["h"], .hold), (.card, ["s"], .stop), (.card, ["q"], .stop), (.card, ["b"], .back), (.card, ["o"], .openCalendar), (.card, ["d"], .doneInCalendar),
            (.confirm, ["o"], nil), (.problem, ["d"], nil),
            (.card, ["g", "2"], .goTo(2)), (.card, ["g", "x"], nil), (.card, ["2"], nil),
            (.card, [ReviewKeyboard.returnKey], nil), (.card, [ReviewKeyboard.escapeKey], nil),
            // Nothing but Return sends, so a stray letter cannot.
            (.confirm, ["y"], nil), (.confirm, ["n"], nil), (.confirm, ["h"], nil),
            (.confirm, [ReviewKeyboard.returnKey], .send), (.confirm, [ReviewKeyboard.escapeKey], .cancel),
            (.problem, ["r"], .refresh), (.problem, ["h"], .hold), (.problem, ["y"], nil),
        ]
        for (mode, keys, expected) in cases {
            var keyboard = ReviewKeyboard()
            var result: ReviewKey?
            for key in keys { result = keyboard.press(key, mode: mode) }
            XCTAssertEqual(result, expected, "\(mode) \(keys)")
        }
    }

    func testGoToForgetsAnAbandonedG() {
        var keyboard = ReviewKeyboard()
        _ = keyboard.press("g", mode: .card)
        _ = keyboard.press("h", mode: .card)
        XCTAssertNil(keyboard.press("1", mode: .card))
    }

    func testCalendarLinkPointsAtTheStartOfTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let noon = Date(timeIntervalSinceReferenceDate: 86_400 * 3 + 43_200)
        XCTAssertEqual(CalendarOpener.url(for: noon, calendar: calendar)?.absoluteString, "calshow:259200")
    }
}
