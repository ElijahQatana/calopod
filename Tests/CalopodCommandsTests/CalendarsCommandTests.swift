@testable import CalopodCommands
import ArgumentParser
import CalopodDomain
@testable import CalopodStore
import Foundation
import Testing

@Suite struct CalendarsCommandTests {
    private func repository() throws -> LocalStateRepository {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "conn", configurationID: "default", provider: "google", displayLabel: "Example", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "conn", bindings: [
            StoredCalendarBinding(id: "work", connectionID: "conn", providerCalendarID: "w", displayLabel: "Work", isSelected: true, isReadOnly: false),
            StoredCalendarBinding(id: "home", connectionID: "conn", providerCalendarID: "h", displayLabel: "Home", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "home2", connectionID: "conn", providerCalendarID: "h2", displayLabel: "Home", isSelected: false, isReadOnly: false),
        ])
        return repository
    }

    @Test func parsing() throws {
        #expect(try CalopodRoot.parseAsRoot(["calendars"]) is CalendarsListCommand)
        #expect(try CalopodRoot.parseAsRoot(["calendars", "--select", "work"]) is CalendarsListCommand)
        #expect(try CalopodRoot.parseAsRoot(["calendars", "name", "work", "--clear"]) is CalendarsNameCommand)
        #expect(throws: (any Error).self) { try CalopodRoot.parseAsRoot(["calendars", "name", "work"]) }
        #expect(throws: (any Error).self) { try CalopodRoot.parseAsRoot(["calendars", "name", "work", "A", "--clear"]) }
    }

    @Test func namesIgnoresAndColors() throws {
        let repository = try repository()
        let named = try CalendarsEdit.name("Work", to: " Office ", repository: repository)
        #expect(named.items?.first?.alias == "Office")
        #expect(named.items?.first?.label == "Work")
        // The shown name finds the calendar too, and the real name keeps working.
        _ = try CalendarsEdit.ignore("Office", true, repository: repository)
        _ = try CalendarsEdit.color("Work", "TEAL", repository: repository)
        let item = try #require(try CalendarsEdit.name("work", to: nil, repository: repository).items?.first)
        #expect(item.alias == nil && item.ignored == true && item.color == "teal")
        #expect(try repository.calendarPreferences()["work"] == CalendarPreference(alias: nil, isIgnored: true, color: "teal"))

        _ = try CalendarsEdit.ignore("work", false, repository: repository)
        #expect(try repository.calendarPreferences()["work"]?.isIgnored == false)
        // A name equal to the real one is the same as no name.
        _ = try CalendarsEdit.name("work", to: "Work", repository: repository)
        #expect(try repository.calendarPreferences()["work"]?.alias == nil)
        #expect(throws: (any Error).self) { try CalendarsEdit.color("work", "magenta", repository: repository) }
        #expect(throws: (any Error).self) { try CalendarsEdit.name("work", to: "  ", repository: repository) }
    }

    @Test func hideAndShowApplyToOneViewOnly() throws {
        let repository = try repository()
        #expect(try CalopodRoot.parseAsRoot(["calendars", "hide", "work", "--view", "sources"]) is CalendarsHideCommand)
        #expect(try CalopodRoot.parseAsRoot(["calendars", "show", "work", "--view", "all"]) is CalendarsShowCommand)
        #expect(throws: (any Error).self) { try CalopodRoot.parseAsRoot(["calendars", "hide", "work"]) }

        _ = try CalendarsEdit.hide("Work", true, view: .sources, repository: repository)
        _ = try CalendarsEdit.hide("home", true, view: .all, repository: repository)
        #expect(try repository.hiddenCalendars(view: "sources") == ["work"])
        #expect(try repository.hiddenCalendars(view: "all") == ["home"])
        #expect(try repository.hiddenCalendars(view: "destinations").isEmpty)
        _ = try CalendarsEdit.hide("work", false, view: .sources, repository: repository)
        #expect(try repository.hiddenCalendars(view: "sources").isEmpty)
        #expect(throws: (any Error).self) { try CalendarsEdit.hide("nope", true, view: .all, repository: repository) }
    }

    @Test func ambiguousAndMissingNamesFail() throws {
        let repository = try repository()
        #expect(try resolveCalendar("home2", repository: repository).id == "home2")
        do {
            _ = try resolveCalendar("Home", repository: repository)
            Issue.record("expected an ambiguity error")
        } catch let error as ValidationError {
            let text = "\(error)"
            #expect(text.contains("home:") && text.contains("home2:"))
        }
        #expect(throws: (any Error).self) { try resolveCalendar("Nope", repository: repository) }
    }

    @Test func listShowsEveryField() throws {
        let repository = try repository()
        _ = try CalendarsEdit.name("work", to: "Office", repository: repository)
        _ = try CalendarsEdit.ignore("home", true, repository: repository)
        let payload = calendarsPayload(try repository.calendarBindings(connectionID: "conn"), message: "Calendars.", repository: repository)
        #expect(payload.colors?.count == 12)
        let json = try OutputRenderer.render(command: "calendars", payload: payload, format: .json)
        #expect(json.contains("\"alias\":\"Office\"") && json.contains("\"label\":\"Work\"") && json.contains("\"ignored\":true"))
        let human = try OutputRenderer.render(command: "calendars", payload: payload, format: .human,
                                              human: HumanOutputContext(connectionLabels: ["conn": "Example"]))
        #expect(human.contains(". Office") && human.contains("Real name: Work") && human.contains("Ignored: yes"))
        #expect(human.contains("Colors: blue, orange"))
    }

    @Test func inboxShowsTheNameAndJSONKeepsTheRealOne() throws {
        let repository = try repository()
        let event = StoredNormalizedInstance(
            sourceKeyHash: "event", connectionID: "conn", calendarBindingID: "work", providerEventID: "e", recurrenceID: nil,
            startsAt: Date(timeIntervalSince1970: 1000), endsAt: Date(timeIntervalSince1970: 2000), isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: "Review", contentFingerprint: "f", providerUpdatedAt: nil, notes: nil,
            currentUserResponse: EventResponse(state: .needsResponse))
        try repository.applyEventRefresh(connectionID: "conn", calendarBindingID: "work", windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 20000), instances: [event], cancelledSourceKeyHashes: [], isFullRefresh: true,
            cursorUpdates: [], now: Date(), removedSourceKeyHashes: [])
        _ = try CalendarsEdit.name("work", to: "Office", repository: repository)
        _ = try CalendarsEdit.ignore("work", true, repository: repository)

        let payload = try InboxCLI.list(repository: repository, options: try InboxOptions.parse([]), range: nil, activity: false,
                                        now: Date(timeIntervalSince1970: 0))
        #expect(payload.items?.count == 1)
        let human = try OutputRenderer.render(command: "inbox", payload: payload, format: .human,
                                              human: HumanOutputContext(connectionLabels: ["conn": "Example"]))
        #expect(human.contains("Calendar: Office") && !human.contains("Work"))
        let json = try OutputRenderer.render(command: "inbox", payload: payload, format: .json)
        #expect(json.contains("\"label\":\"Work\"") && json.contains("\"alias\":\"Office\"") && json.contains("\"ignored\":true"))
    }

    @Test func prunePreferencesCountsFirstAndKeepsRealCalendars() throws {
        #expect(try CalopodRoot.parseAsRoot(["calendars", "prune-preferences", "--dry-run"]) is CalendarsPrunePreferencesCommand)
        let repository = try repository()
        _ = try CalendarsEdit.name("work", to: "Office", repository: repository)
        try repository.setCalendarAlias("Leftover", calendarID: "fam")
        try repository.setCalendarColor("red", calendarID: "hol")

        let dry = try CalendarsEdit.prune(dryRun: true, repository: repository)
        #expect(dry.count == 2 && dry.message.contains("would be removed"))
        #expect(try repository.calendarPreferences().count == 3)

        let done = try CalendarsEdit.prune(dryRun: false, repository: repository)
        #expect(done.count == 2)
        #expect(Set(try repository.calendarPreferences().keys) == ["work"])
        #expect(try CalendarsEdit.prune(dryRun: false, repository: repository).message == "Nothing to remove.")
    }

    @Test func everyReadPathUsesTheChosenName() throws {
        let repository = try repository()
        _ = try CalendarsEdit.name("work", to: "Office", repository: repository)
        // A blank name left in the database counts as no name.
        try repository.database.write {
            try $0.execute(sql: "INSERT INTO calendar_preferences (calendar_id, alias) VALUES ('home', '')")
        }
        let names = CalendarNames(repository)

        // events and read: the source carries the alias, sync preview and arms: the label map.
        let source = names.source(CommandSource(id: "work", connectionID: "conn", provider: "google", label: "Work"))
        #expect(source.alias == "Office")
        #expect(names.source(CommandSource(id: "home", connectionID: "conn", provider: "google", label: "Home")).alias == nil)
        let context = try OutputOptions.parse([]).localContext(repository: repository)
        #expect(context.calendarLabels["work"] == "Office" && context.calendarLabels["home"] == "Home")

        // The inbox review terminal and the Inbox list read through this same lookup.
        #expect(names.shown("work", real: "Work") == "Office" && names.shown("home", real: "Home") == "Home")
    }
}
