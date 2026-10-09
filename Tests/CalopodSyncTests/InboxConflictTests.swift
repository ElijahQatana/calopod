import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Inbox calendar context and conflicts")
struct InboxConflictTests {
    let window = try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100_000))
    let cutoff = Date(timeIntervalSince1970: 100)

    @Test("Long focus retains exact conflicts beyond clipped context across sources")
    func longContext() throws {
        let focus = event("a", start: 10_000, end: 30_000)
        let near = event("b", binding: "other", start: 11_000, end: 12_000)
        let far = event("c", binding: "other", start: 29_000, end: 31_000)
        let preview = try context([focus, near, far])
        #expect(preview.focused.event.endsAt == date(30_000))
        #expect(preview.visibleWindow.start == date(4_600))
        #expect(preview.visibleWindow.end == date(15_400))
        #expect(preview.rows.map(\.event.event.sourceKeyHash) == ["a", "b"])
        #expect(preview.rows[0].visibleInterval.end == date(15_400))
        #expect(preview.focusedConflicts.map(\.pair) == [InboxConflictPair("a", "b"), InboxConflictPair("a", "c")])
        #expect(try preview.focusedConflicts[1].overlap == SyncWindow(start: date(29_000), end: date(30_000)))
        #expect(preview.rows[1].source.calendarLabel == "Other calendar")
        #expect(preview.attentionReasons == [.conflict])
        #expect(preview.projections.first(where: { $0.choice == .no })?.conflicts.isEmpty == true)
        #expect(preview.projections.first(where: { $0.choice == .yes })?.conflicts == preview.focusedConflicts)
        #expect(preview.projections.first(where: { $0.choice == .maybe })?.conflicts == preview.focusedConflicts)
    }

    @Test("Touching, free, cancelled and declined events do not conflict; tentative occupancy stays busy")
    func occupancy() {
        let events = [event("a"), event("touch", start: 12_000, end: 13_000),
                      event("free", availability: "free"), event("cancel", cancelled: true),
                      event("declined", response: .declined),
                      event("tentative-accepted", availability: "tentative", response: .accepted)]
        let analysis = analyze(events)
        #expect(analysis.pairs == [InboxConflictPair("a", "tentative-accepted")])
        #expect(InboxConflictCalculator.conflictOnlyEvents(in: snapshot(events), analysis: analysis).map(\.event.sourceKeyHash) == ["a", "tentative-accepted"])
    }

    @Test("Unproven same-title copies and three-event groups retain separate pair identities")
    func groups() throws {
        let events = [event("a"), event("b", binding: "other"), event("c", start: 11_000, end: 13_000)]
        let snap = snapshot(events, unproven: ["other"])
        let preview = try InboxCalendarContextBuilder.build(snapshot: snap, focusedKey: "a", settings: InboxContextSettings(), freshnessCutoff: cutoff)
        #expect(preview.analysis.pairs.count == 3)
        #expect(preview.conflictGroup.map(\.event.sourceKeyHash) == ["a", "b", "c"])
        #expect(preview.analysis.warnings.contains { $0.kind == .unprovenDuplicate })
        #expect(InboxConflictPair("a", "b") == InboxConflictPair("b", "a"))
        #expect(InboxConflictPair("a|b", "c") != InboxConflictPair("a", "b|c"))
    }

    @Test("All-day events preserve local day and daylight-saving endpoints")
    func daylightSaving() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(end.timeIntervalSince(start) == 25 * 3600)
        let allDay = event("a", start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, allDay: true)
        let late = event("b", start: end.timeIntervalSince1970 - 3600, end: end.timeIntervalSince1970 + 3600)
        let sources = [source("calendar", coverageStart: start.addingTimeInterval(-10_000), coverageEnd: end.addingTimeInterval(10_000)), source("other", coverageStart: start.addingTimeInterval(-10_000), coverageEnd: end.addingTimeInterval(10_000))]
        let preview = try InboxCalendarContextBuilder.build(snapshot: InboxContextSnapshot(sources: sources, events: [allDay, late].map { InboxContextEvent(event: $0) }), focusedKey: "a", settings: InboxContextSettings(), freshnessCutoff: cutoff)
        #expect(preview.focused.event.isAllDay)
        #expect(preview.focusedConflicts[0].overlap.end == end)
        #expect(preview.focusedConflicts[0].overlap.start == end.addingTimeInterval(-3600))
        #expect(preview.rows.count == 1)
        #expect(preview.visibleWindow.end.timeIntervalSince(start) == 90 * 60)
    }

    @Test("Connected group follows a long neighbor outside focused context")
    func transitiveGroup() throws {
        let preview = try context([event("a"), event("b", start: 11_000, end: 30_000), event("c", start: 29_000, end: 31_000)])
        #expect(preview.focusedConflicts.map(\.pair) == [InboxConflictPair("a", "b")])
        #expect(preview.conflictGroup.map(\.event.sourceKeyHash) == ["a", "b", "c"])
        #expect(preview.choices.map(\.sourceKeyHash) == ["a", "b", "c"])
        #expect(preview.rows.map(\.event.event.sourceKeyHash) == ["a", "b"])
    }

    @Test("Declined focus projects Yes and Maybe without editing either event")
    func projections() throws {
        let events = [event("a", response: .declined), event("b")]
        let preview = try context(events)
        #expect(preview.focusedConflicts.isEmpty)
        #expect(preview.focused.event.currentUserResponse.state == .declined)
        #expect(preview.projections.filter { !$0.conflicts.isEmpty }.map(\.choice) == [.yes, .maybe])
        #expect(preview.snapshot == snapshot(events))
        #expect(try context([event("a", availability: "free"), event("b")]).projections.allSatisfy { $0.conflicts.isEmpty })
    }

    @Test("Choices require verified provider capability and occurrence scope; Hold is always local")
    func choices() throws {
        let supported = event("a", supported: true)
        let preview = try context([supported, event("b", response: .organizer)])
        #expect(preview.choices[0].choices == [.yes, .no, .maybe, .hold])
        #expect(preview.choices[1].requiresManualProviderEdit)
        #expect(preview.choices[1].unavailableReasons.contains(.notAnInvitation))
        #expect(try InboxCalendarContextBuilder.revalidate(preview, against: preview.snapshot, chosenKey: "a", choice: .no, freshnessCutoff: cutoff).event == supported)
        #expect(throws: InboxCalendarContextError.actionUnavailable) {
            try InboxCalendarContextBuilder.revalidate(preview, against: preview.snapshot, chosenKey: "b", choice: .yes, freshnessCutoff: cutoff)
        }
        for provider in ["eventkit", "ics"] {
            let snap = InboxContextSnapshot(sources: [source("calendar", provider: provider)], events: [InboxContextEvent(event: supported)])
            #expect(InboxCalendarContextBuilder.choices(for: snap.events[0], snapshot: snap).choices == [.hold])
        }
        let unverified = InboxContextSnapshot(sources: [source("calendar", identity: .unverified)], events: [InboxContextEvent(event: supported)])
        #expect(InboxCalendarContextBuilder.choices(for: unverified.events[0], snapshot: unverified).unavailableReasons.contains(.identityUnverified))
        let series = event("a", supported: true, scopes: [.series])
        #expect(InboxCalendarContextBuilder.choices(for: InboxContextEvent(event: series), snapshot: snapshot([series])).choices == [.hold])
    }

    @Test("Stale, missing and incomplete source inputs cannot claim conflict-free completeness")
    func warnings() throws {
        let stale = source("calendar", observed: date(1), status: "stale")
        let unknown = InboxContextSource(bindingID: "other", connectionID: "other", provider: "ics")
        let snap = InboxContextSnapshot(sources: [stale, unknown], events: [InboxContextEvent(event: event("a", supported: true))])
        let preview = try InboxCalendarContextBuilder.build(snapshot: snap, focusedKey: "a", settings: InboxContextSettings(), freshnessCutoff: cutoff)
        #expect(!preview.analysis.isComplete)
        #expect(Set(preview.analysis.warnings.map(\.kind)) == [.staleSource, .unknownSource, .incompleteCoverage])
        #expect(try InboxCalendarContextBuilder.revalidate(preview, against: snap, chosenKey: "a", choice: .yes, freshnessCutoff: cutoff).event.sourceKeyHash == "a")
        #expect(try InboxCalendarContextBuilder.revalidate(preview, against: snap, chosenKey: "a", choice: .hold, freshnessCutoff: cutoff).event.sourceKeyHash == "a")
        #expect(!InboxConflictCalculator.analyze(InboxContextSnapshot(sources: [], events: []), window: window, freshnessCutoff: cutoff).isComplete)
        #expect(!analyze([event("a", availability: "unsupported")]).isComplete)
        #expect(analyze([event("a", response: .unknown)]).warnings.contains { $0.kind == .unknownResponse })
    }

    @Test("Changes to focus, another event, selection or freshness require another preview")
    func races() throws {
        let preview = try context([event("a", supported: true), event("b")])
        for changed in [snapshot([event("a", end: 13_000, supported: true), event("b")]),
                        snapshot([event("a", supported: true), event("b", response: .declined)]),
                        InboxContextSnapshot(sources: [source("calendar")], events: preview.snapshot.events)] {
            #expect(throws: InboxCalendarContextError.previewChanged) {
                try InboxCalendarContextBuilder.revalidate(preview, against: changed, chosenKey: "a", choice: .no, freshnessCutoff: cutoff)
            }
        }
        #expect(throws: InboxCalendarContextError.previewChanged) {
            try InboxCalendarContextBuilder.revalidate(preview, against: preview.snapshot, chosenKey: "a", choice: .yes, freshnessCutoff: date(501))
        }
        #expect(try context([event("a"), event("b", response: .declined)]).focusedConflicts.isEmpty)
    }

    func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    func event(_ key: String, binding: String = "calendar", start: Double = 10_000, end: Double = 12_000,
               availability: String = "busy", response: EventResponseState = .accepted, cancelled: Bool = false,
               allDay: Bool = false, supported: Bool = false, scopes: [RSVPActionScope] = [.occurrence]) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: binding, calendarBindingID: binding,
            providerEventID: key, recurrenceID: nil, startsAt: date(start), endsAt: date(end), isAllDay: allDay,
            availability: availability, isCancelled: cancelled, isPrivate: false, title: "Synthetic event",
            contentFingerprint: "synthetic", providerUpdatedAt: nil,
            currentUserResponse: EventResponse(state: response, evidence: .googleSelf,
                actionCapability: supported ? RSVPActionCapability(supportedScopes: scopes) : nil))
    }
    func source(_ binding: String, provider: String = "google", identity: ResponseIdentityScope = .authenticatedUser,
                coverageStart: Date? = nil, coverageEnd: Date? = nil,
                observed: Date = Date(timeIntervalSince1970: 500), status: String = "healthy") -> InboxContextSource {
        InboxContextSource(bindingID: binding, connectionID: binding, connectionLabel: "Example Connection",
            calendarLabel: binding == "calendar" ? "Example calendar" : "Other calendar", provider: provider,
            responseIdentityScope: identity,
            coverage: InboxCoverage(startsAt: coverageStart ?? date(0), endsAt: coverageEnd ?? date(100_000), observedAt: observed), healthStatus: status)
    }
    func snapshot(_ events: [StoredNormalizedInstance], unproven: Set<String> = []) -> InboxContextSnapshot {
        InboxContextSnapshot(sources: [source("calendar"), source("other")], events: events.map { InboxContextEvent(event: $0) }, unprovenDuplicateBindingIDs: unproven)
    }
    func analyze(_ events: [StoredNormalizedInstance]) -> InboxConflictAnalysis {
        InboxConflictCalculator.analyze(snapshot(events), window: window, freshnessCutoff: cutoff)
    }
    func context(_ events: [StoredNormalizedInstance]) throws -> InboxCalendarContext {
        try InboxCalendarContextBuilder.build(snapshot: snapshot(events), focusedKey: "a", settings: InboxContextSettings(), freshnessCutoff: cutoff)
    }
}
