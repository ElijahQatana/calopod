import CalopodCommands
import Foundation
import Testing

private let newYork = TimeZone(identifier: "America/New_York")!
private let utc = TimeZone(secondsFromGMT: 0)!

@Test
func dayUsesTheRequestedLocalCalendarDay() throws {
    let resolved = try DateRangeResolver(day: "2026-09-24", timezone: "America/New_York")
        .resolve(default: .none, systemTimeZone: utc)
    let range = try #require(resolved)

    #expect(range.timeZoneIdentifier == "America/New_York")
    #expect(range.window.end.timeIntervalSince(range.window.start) == 86_400)
}

@Test
func springDaylightSavingDayIsTwentyThreeHours() throws {
    let resolved = try DateRangeResolver(day: "2026-03-08", timezone: "America/New_York")
        .resolve(default: .none, systemTimeZone: utc)
    let range = try #require(resolved)

    #expect(range.window.end.timeIntervalSince(range.window.start) == 82_800)
}

@Test
func fallDaylightSavingDayIsTwentyFiveHours() throws {
    let resolved = try DateRangeResolver(day: "2026-11-01", timezone: "America/New_York")
        .resolve(default: .none, systemTimeZone: utc)
    let range = try #require(resolved)

    #expect(range.window.end.timeIntervalSince(range.window.start) == 90_000)
}

@Test
func dateOnlyThroughIncludesTheCompleteDay() throws {
    let resolved = try DateRangeResolver(
        from: "2026-09-24",
        through: "2026-10-01",
        timezone: "America/New_York"
    ).resolve(default: .none, systemTimeZone: utc)
    let range = try #require(resolved)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    let end = calendar.dateComponents([.year, .month, .day], from: range.window.end)
    #expect(end.year == 2026)
    #expect(end.month == 10)
    #expect(end.day == 2)
}

@Test
func timestampBoundariesStayExact() throws {
    let resolved = try DateRangeResolver(
        from: "2026-09-24T09:00:00-04:00",
        through: "2026-09-24T17:00:00-04:00"
    ).resolve(default: .none, systemTimeZone: utc)
    let range = try #require(resolved)

    #expect(range.window.end.timeIntervalSince(range.window.start) == 28_800)
}

@Test
func currentDayDefaultUsesTheSelectedTimezone() throws {
    let now = Date(timeIntervalSince1970: 1_798_722_000)
    let resolved = try DateRangeResolver(timezone: "America/New_York")
        .resolve(default: .currentDay, now: now, systemTimeZone: utc)
    let range = try #require(resolved)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    #expect(range.window.start == calendar.startOfDay(for: now))
}

@Test
func dayAndRangeAreMutuallyExclusive() {
    let resolver = DateRangeResolver(
        day: "2026-09-24",
        from: "2026-09-24",
        through: "2026-09-25"
    )

    #expect(throws: DateRangeInputError.conflictingDayAndRange) {
        try resolver.resolve(default: .none, systemTimeZone: utc)
    }
}

@Test
func aRangeRequiresBothBoundaries() {
    #expect(throws: DateRangeInputError.incompleteRange) {
        try DateRangeResolver(from: "2026-09-24")
            .resolve(default: .none, systemTimeZone: utc)
    }
}

@Test
func invalidCalendarDatesAreRejected() {
    #expect(throws: DateRangeInputError.invalidDate("2026-02-30")) {
        try DateRangeResolver(day: "2026-02-30")
            .resolve(default: .none, systemTimeZone: utc)
    }
}

@Test
func timestampRequiresAnExplicitOffset() {
    #expect(throws: DateRangeInputError.invalidTimestamp("2026-09-24T09:00:00")) {
        try DateRangeResolver(
            from: "2026-09-24T09:00:00",
            through: "2026-09-24T17:00:00"
        ).resolve(default: .none, systemTimeZone: utc)
    }
}

@Test
func unknownTimezoneIsRejected() {
    #expect(throws: DateRangeInputError.invalidTimeZone("Mars/Olympus")) {
        try DateRangeResolver(day: "2026-09-24", timezone: "Mars/Olympus")
            .resolve(default: .none, systemTimeZone: utc)
    }
}
