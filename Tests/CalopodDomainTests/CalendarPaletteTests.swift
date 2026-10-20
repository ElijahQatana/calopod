import Testing

@testable import CalopodDomain

struct CalendarPaletteTests {
    @Test
    func idsAreUniqueAndNeutralIsGray() {
        #expect(Set(CalendarPalette.entries.map(\.id)).count == 12)
        #expect(CalendarPalette.neutral.id == "gray")
    }

    @Test(arguments: CalendarPalette.entries.enumerated().map { ($0.offset, $0.element) })
    func idAndPositionFindTheSameEntry(position: Int, entry: CalendarPaletteEntry) {
        #expect(CalendarPalette.entry(id: entry.id) == entry)
        #expect(CalendarPalette.entry(id: entry.id, position: nil) == entry)
        #expect(CalendarPalette.entry(id: nil, position: position) == entry)
        #expect(CalendarPalette.entry(id: entry.id, position: 0) == entry)
    }

    @Test
    func anUnknownOrMissingChoiceIsNeutral() {
        #expect(CalendarPalette.entry(id: "mauve", position: 4) == CalendarPalette.neutral)
        #expect(CalendarPalette.entry(id: nil, position: 12) == CalendarPalette.neutral)
        #expect(CalendarPalette.entry(id: nil, position: -1) == CalendarPalette.neutral)
        #expect(CalendarPalette.entry(id: nil, position: nil) == CalendarPalette.neutral)
    }
}
