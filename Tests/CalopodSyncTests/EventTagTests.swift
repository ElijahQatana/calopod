import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodSync

@Suite("Event tags")
struct EventTagTests {
    @Test("A tag is read whole, in any case, from the notes first and then the title", arguments: [
        ("Lunch #dontclone", nil, [.dontClone]), ("Lunch #DontClone", nil, [.dontClone]),
        ("Lunch", "call back\n#justbusy", [.justBusy]), ("(#JUSTBUSY)", "", [.justBusy]),
        ("Lunch #dontclone.", nil, [.dontClone]),
        ("#dontclone", "#justbusy", [.justBusy]),
        (nil, "#dontclone #justbusy", [.dontClone, .justBusy]),
        ("Lunch #dontcloned", nil, []), ("Lunch dontclone", nil, []), ("Lunch #dont-clone", nil, []),
        ("Lunch #dont clone", "x#justbusy", []), ("Lunch ##justbusy", nil, []),
        ("Lunch #justbusy-later", nil, []), (nil, nil, []),
    ] as [(String?, String?, Set<EventTag>)])
    func reads(title: String?, notes: String?, tags: Set<EventTag>) {
        #expect(EventTag.read(event(title: title, notes: notes)) == tags)
    }
}

private func event(
    title: String? = "Review", notes: String? = nil, location: String? = nil, isPrivate: Bool = false,
    response: EventResponseState = .notApplicable
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-a", connectionID: "connection", calendarBindingID: "source", providerEventID: "id-a", recurrenceID: nil,
        startsAt: Date(timeIntervalSince1970: 2_000), endsAt: Date(timeIntervalSince1970: 3_000), isAllDay: false,
        availability: "busy", isCancelled: false, isPrivate: isPrivate, title: title, contentFingerprint: "f-a",
        providerUpdatedAt: nil, location: location, notes: notes, currentUserResponse: EventResponse(state: response))
}
