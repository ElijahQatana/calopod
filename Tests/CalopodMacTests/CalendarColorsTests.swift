import XCTest

@testable import CalopodMac

final class CalendarColorsTests: XCTestCase {
    func testPaletteHasTwelveDistinctColors() {
        XCTAssertEqual(Set(CalendarColor.palette.map(\.id)).count, 12)
        XCTAssertEqual(Set(CalendarColor.palette.map(\.light)).count, 12)
    }

    func testSuggestionFollowsUsedColors() {
        let cases: [(used: [String], expected: (String) -> Bool, note: String)] = [
            ([], { $0 == "blue" }, "empty starts at the first color"),
            (["blue"], { $0 != "blue" && $0 != "indigo" && $0 != "sky" }, "far from blue"),
            (["blue", "orange"], { !["blue", "orange"].contains($0) }, "never reuses while free colors remain"),
        ]
        for item in cases {
            XCTAssertTrue(item.expected(CalendarColor.suggestion(avoiding: item.used).id), item.note)
        }
    }

    func testMoreCalendarsThanColorsSpreadEvenly() {
        var used: [String] = []
        for _ in 0..<30 { used.append(CalendarColor.suggestion(avoiding: used).id) }
        let counts = Dictionary(grouping: used, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts.count, 12)
        XCTAssertTrue(counts.values.allSatisfy { (2...3).contains($0) })
    }

    func testSuggestionIsStable() {
        let used = ["teal", "red", "teal"]
        XCTAssertEqual(CalendarColor.suggestion(avoiding: used), CalendarColor.suggestion(avoiding: used))
    }

    @MainActor
    func testChoicesPersistLocallyAndAreKept() throws {
        let name = "calopod.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = CalendarColors(defaults: defaults)
        first.assignMissing(to: ["work@example.com", "home@example.com"])
        let work = first.color(for: "work@example.com")
        XCTAssertNotEqual(work, first.color(for: "home@example.com"))

        let red = try XCTUnwrap(CalendarColor.named("red"))
        first.set(red, for: "home@example.com")
        first.assignMissing(to: ["work@example.com", "home@example.com"])

        let reopened = CalendarColors(defaults: defaults)
        XCTAssertEqual(reopened.color(for: "work@example.com"), work)
        XCTAssertEqual(reopened.color(for: "home@example.com"), red)
    }
}
