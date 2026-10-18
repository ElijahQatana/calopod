import CalopodStore
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

        let ids = ["work@example.com", "home@example.com"].map { CalendarColorSource(id: $0) }
        let state = LocalStateRepository(database: try .inMemory())
        let first = CalendarColors(defaults: defaults, state: state)
        first.assignMissing(to: ids)
        let work = first.color(for: "work@example.com")
        XCTAssertNotEqual(work, first.color(for: "home@example.com"))

        let red = try XCTUnwrap(CalendarColor.named("red"))
        first.set(red, for: "home@example.com")
        first.assignMissing(to: ids)

        let reopened = CalendarColors(defaults: defaults, state: state)
        XCTAssertEqual(reopened.color(for: "work@example.com"), work)
        XCTAssertEqual(reopened.color(for: "home@example.com"), red)
    }

    func testNearestPaletteColorForProviderHex() {
        let cases: [(hex: String, id: String?)] = [
            ("#3a5fcd", "blue"), ("#d9731a", "orange"), ("#ff2d55", "red"), ("#16a765", "green"),
            ("#808080", "gray"), ("not a color", nil), ("#12", nil),
        ]
        for item in cases { XCTAssertEqual(CalendarColor.nearest(toHex: item.hex)?.id, item.id, item.hex) }
    }

    @MainActor
    func testProviderColorsStayDefaultsUntilChosen() throws {
        let name = "calopod.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let colors = CalendarColors(defaults: defaults, state: nil)
        let sources = [
            CalendarColorSource(id: "mac", providerColor: "#d9731a", provider: "eventkit"),
            CalendarColorSource(id: "mac-none", providerColor: nil, provider: "eventkit"),
            CalendarColorSource(id: "google", providerColor: "#16a765", provider: "google"),
        ]
        colors.assignMissing(to: sources)

        // Mac starts from the Calendar app color; Google keeps a suggestion until asked.
        XCTAssertEqual(colors.color(for: "mac").id, "orange")
        XCTAssertNotNil(colors.choices["mac-none"])
        XCTAssertNotEqual(colors.color(for: "google").id, "orange")
        XCTAssertEqual(colors.providerMatch(for: "google")?.name, "Google")

        colors.matchProvider(for: "google")
        XCTAssertEqual(colors.color(for: "google").id, "green")
        XCTAssertNil(colors.providerMatch(for: "mac-none"))

        // A later pass with a different provider color does not undo a choice.
        let purple = try XCTUnwrap(CalendarColor.named("purple"))
        colors.set(purple, for: "mac")
        colors.assignMissing(to: [CalendarColorSource(id: "mac", providerColor: "#c8453b", provider: "eventkit")])
        XCTAssertEqual(colors.color(for: "mac"), purple)
    }
}
