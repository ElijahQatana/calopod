@testable import CalopodStore
import Testing

@Suite struct CalendarViewHiddenStoreTests {
    @Test func eachViewKeepsItsOwnHiddenCalendars() throws {
        let repository = LocalStateRepository(database: try .inMemory())
        #expect(try repository.hiddenCalendars(view: "all").isEmpty)
        try repository.setCalendarHidden(true, view: "all", calendarID: "work")
        try repository.setCalendarHidden(true, view: "all", calendarID: "work")
        try repository.setCalendarHidden(true, view: "sources", calendarID: "hub")
        #expect(try repository.hiddenCalendars(view: "all") == ["work"])
        #expect(try repository.hiddenCalendars(view: "sources") == ["hub"])
        #expect(try repository.hiddenCalendars(view: "destinations").isEmpty)
        try repository.setCalendarHidden(false, view: "all", calendarID: "work")
        #expect(try repository.hiddenCalendars(view: "all").isEmpty)
        #expect(try repository.hiddenCalendars(view: "sources") == ["hub"])
    }
}
