import CalopodDomain
import CalopodEventKit
import CalopodProviders
import EventKit
import Foundation
import Testing

@Suite("EventKit current user response")
struct EventKitResponseTests {
    @Test(arguments: [EKParticipantStatus.pending, .accepted, .tentative, .declined, .unknown, .delegated, .completed, .inProcess])
    func responseStates(_ status: EKParticipantStatus) {
        let response = EventKitResponseNormalizer.response(
            organizerIsCurrentUser: false,
            participants: [.init(isCurrentUser: false, status: .pending),
                           .init(isCurrentUser: true, status: status)], sourceType: "caldav")
        let expected: [EKParticipantStatus: EventResponseState] = [
            .pending: .needsResponse, .accepted: .accepted, .tentative: .tentative, .declined: .declined,
        ]
        #expect(response.state == (expected[status] ?? .unknown))
        #expect(response.evidence == .eventKitCurrentUser)
        #expect(response.respondedAt == nil)
        #expect(response.actionCapability.unavailableReasons.contains(.providerReadOnly))
    }

    @Test
    func organizerMissingAndSharedIdentity() {
        let organizer = EventKitResponseNormalizer.response(organizerIsCurrentUser: true,
                                                             participants: [], sourceType: "exchange")
        #expect(organizer.state == .organizer)
        for participants: [EventKitResponseParticipant] in [[], [.init(isCurrentUser: false, status: .accepted)],
                                                            [.init(isCurrentUser: true, status: .pending),
                                                             .init(isCurrentUser: true, status: .accepted)]] {
            let response = EventKitResponseNormalizer.response(organizerIsCurrentUser: false,
                                                                participants: participants, sourceType: "exchange")
            #expect(response.state == .unknown)
        }
        let birthday = EventKitResponseNormalizer.response(organizerIsCurrentUser: false,
                                                            participants: [], sourceType: "birthdays")
        #expect(birthday.state == .notApplicable)
    }

    @Test
    func hostProtocolRoundTripAndEarlierHostCompatibility() throws {
        let event = ProviderEvent(provider: "eventkit", connectionID: "eventkit-device",
                                  calendarID: "synthetic-calendar", eventID: "synthetic-event",
                                  seriesID: nil, originalStart: nil, start: Date(), end: Date(),
                                  isAllDay: false, availability: .tentative, isCancelled: false,
                                  isPrivate: false, title: "Synthetic", updatedAt: nil,
                                  responseMetadata: EventResponse(state: .accepted, evidence: .eventKitCurrentUser))
        let wire = try JSONEncoder().encode(EventKitHostResponse(status: .fullAccess, events: [event]))
        let decoded = try JSONDecoder().decode(EventKitHostResponse.self, from: wire)
        #expect(decoded.events[0].currentUserResponse.state == .accepted)
        #expect(decoded.events[0].availability == .tentative)
        #expect(event.markingManagedMirror().currentUserResponse == event.currentUserResponse)
        var object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        var events = try #require(object["events"] as? [[String: Any]])
        events[0].removeValue(forKey: "responseMetadata")
        object["events"] = events
        let oldWire = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(EventKitHostResponse.self, from: oldWire)
        #expect(old.events[0].currentUserResponse == .unavailable)
    }
}
