import CalopodDomain
import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A calendar as Google's Calendar List API reports it.
public struct GoogleCalendar: Equatable, Sendable {
    public let id: String
    public let summary: String?
    public let timeZone: String?
    public let accessRole: String
    public let primary: Bool

    public init(id: String, summary: String?, timeZone: String?, accessRole: String, primary: Bool) {
        self.id = id
        self.summary = summary
        self.timeZone = timeZone
        self.accessRole = accessRole
        self.primary = primary
    }
}

/// Thin, direct client over the Google Calendar v3 REST API. Holds no OAuth
/// or connection state itself — `GoogleConnectionService` supplies a fresh
/// access token on every call — so this only needs to know how to talk to
/// Google, not how Calopod manages Google connections.
public struct GoogleCalendarClient: Sendable {
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func calendars(accessToken: String) async throws -> [GoogleCalendar] {
        var calendars: [GoogleCalendar] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("users/me/calendarList"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] }
            guard let url = components?.url else {
                throw ProviderFailure.invalidResponse
            }
            let response = try await send(url: url, accessToken: accessToken)
            let page: CalendarListResponse = try decode(response)
            calendars.append(contentsOf: page.items.map {
                GoogleCalendar(
                    id: $0.id,
                    summary: $0.summary,
                    timeZone: $0.timeZone,
                    accessRole: $0.accessRole,
                    primary: $0.primary ?? false
                )
            })
            pageToken = page.nextPageToken
        } while pageToken != nil

        return calendars
    }

    public func events(
        accessToken: String,
        connectionID: String,
        calendarID: String,
        from start: Date,
        through end: Date,
        updatedSince: Date? = nil,
        responseIdentityScope: ResponseIdentityScope = .unverified
    ) async throws -> ProviderEventPage {
        var events: [ProviderEvent] = []
        var pageToken: String?
        var nextSyncToken: String?

        repeat {
            let endpoint = baseURL
                .appendingPathComponent("calendars", isDirectory: true)
                .appendingPathComponent(calendarID, isDirectory: true)
                .appendingPathComponent("events")
            var components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )
            var query = [
                URLQueryItem(name: "timeMin", value: RFC3339.string(from: start)),
                URLQueryItem(name: "timeMax", value: RFC3339.string(from: end)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let updatedSince {
                query.append(URLQueryItem(name: "updatedMin", value: RFC3339.string(from: updatedSince)))
            }
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = query
            guard let url = components?.url else {
                throw ProviderFailure.invalidResponse
            }

            let response = try await send(url: url, accessToken: accessToken)
            let page: EventListResponse = try decode(response)
            let fallbackTimeZone = page.timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
            events.append(contentsOf: page.items.map {
                $0.providerEvent(
                    connectionID: connectionID,
                    calendarID: calendarID,
                    fallbackTimeZone: fallbackTimeZone,
                    responseIdentityScope: responseIdentityScope
                )
            })
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil

        return ProviderEventPage(events: events, nextSyncToken: nextSyncToken)
    }

    public func rsvpSnapshot(accessToken: String, target: RSVPTarget,
                             authorization: RSVPAuthorization) async throws -> RSVPEventSnapshot {
        guard target.provider == "google", !target.eventID.isEmpty, !target.calendarID.isEmpty,
              !target.eventID.contains("/"), !target.calendarID.contains("/") else {
            throw RSVPActionError.unavailable(.identity)
        }
        let response = try await send(url: eventCollectionURL(calendarID: target.calendarID)
            .appendingPathComponent(target.eventID), accessToken: accessToken)
        let event: GoogleEvent = try decode(response)
        guard event.id == target.eventID, event.recurringEventID == target.seriesID,
              event.originalStartTime?.identity == target.originalStart else { throw RSVPActionError.stale }
        let normalized = event.providerEvent(connectionID: target.connectionID, calendarID: target.calendarID,
                                             fallbackTimeZone: .gmt, responseIdentityScope: authorization.identityScope)
        var reasons: [RSVPUnavailableReason] = []
        if authorization.identityScope != .authenticatedUser { reasons.append(.identityUnverified) }
        if !authorization.canRespond { reasons.append(.permissionUnverified) }
        if normalized.isManagedMirror { reasons.append(.managedMirror) }
        if normalized.isCancelled || normalized.currentUserResponse.state == .organizer
            || event.organizer?.email == nil { reasons.append(.notAnInvitation) }
        if [.unknown, .notApplicable].contains(normalized.currentUserResponse.state)
            || event.attendees?.filter({ $0.isSelf == true }).first?.email == nil {
            reasons.append(.unsupportedResponse)
        }
        let single = event.recurringEventID == nil && event.originalStartTime?.identity == nil
        let occurrence = event.recurringEventID != nil && event.originalStartTime?.identity != nil
            && event.recurringEventID != event.id
        if event.recurrence != nil || (!single && !occurrence) {
            reasons.append(.unsupportedScope)
        }
        let version = event.etag ?? response.headers["etag"]
        if version?.isEmpty != false { reasons.append(.staleRevision) }
        return RSVPEventSnapshot(target: target, event: normalized, version: version,
            capability: reasons.isEmpty ? RSVPActionCapability(supportedScopes: [.occurrence])
                : RSVPActionCapability(unavailableReasons: reasons),
            notification: .googleAllGuests, concurrency: .conditionalUpdate,
            currentUserEmail: event.attendees?.first(where: { $0.isSelf == true })?.email)
    }

    public func submitRSVP(accessToken: String, intent: RSVPActionIntent,
                           authorization: RSVPAuthorization) async throws {
        let snapshot = try await rsvpSnapshot(accessToken: accessToken, target: intent.target, authorization: authorization)
        try snapshot.validate(intent)
        // attendeesOmitted updates only this participant; no event details or other guests are sent.
        let response = snapshot.event.currentUserResponse
        guard response.evidence == .googleSelf else { throw RSVPActionError.unavailable(.identity) }
        guard let email = snapshot.currentUserEmail else { throw RSVPActionError.unavailable(.identity) }
        var components = URLComponents(url: eventCollectionURL(calendarID: intent.target.calendarID)
            .appendingPathComponent(intent.target.eventID), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        guard let url = components?.url else { throw RSVPActionError.unavailable(.unsupported) }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(intent.expectedVersion, forHTTPHeaderField: "If-Match")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "attendeesOmitted": true,
            "attendees": [["email": email, "responseStatus": intent.decision.googleStatus]],
        ])
        do { _ = try await send(request: request, accessToken: accessToken) }
        catch { throw RSVPActionError.writeFailure(error) }
    }

    public func reconcileRSVP(accessToken: String, record: RSVPActionRecord,
                              authorization: RSVPAuthorization) async throws -> RSVPActionOutcome {
        do {
            let snapshot = try await rsvpSnapshot(accessToken: accessToken, target: record.intent.target, authorization: authorization)
            return RSVPReadback.outcome(record, snapshot: snapshot)
        } catch ProviderFailure.httpStatus(404) {
            return RSVPReadback.missing(record)
        } catch ProviderFailure.cursorExpired {
            return RSVPReadback.missing(record)
        }
    }

    public func managedEvents(
        accessToken: String,
        calendarID: String,
        from start: Date,
        through end: Date
    ) async throws -> [ManagedEventSnapshot] {
        var snapshots: [ManagedEventSnapshot] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(
                url: eventCollectionURL(calendarID: calendarID),
                resolvingAgainstBaseURL: false
            )
            var query = [
                URLQueryItem(name: "timeMin", value: RFC3339.string(from: start)),
                URLQueryItem(name: "timeMax", value: RFC3339.string(from: end)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = query
            guard let url = components?.url else { throw ProviderFailure.invalidResponse }
            let response = try await send(url: url, accessToken: accessToken)
            let page: EventListResponse = try decode(response)
            let fallbackTimeZone = page.timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
            snapshots.append(contentsOf: page.items.map {
                $0.managedSnapshot(fallbackTimeZone: fallbackTimeZone)
            })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return snapshots
    }

    /// Creates a managed event using a deterministic ID derived from the
    /// mirror key rather than letting Google assign a random one. That makes
    /// create idempotent: if a create already succeeded but the response was
    /// lost (a network drop, a crash before the mapping was saved), retrying
    /// hits a 409 for an ID that already exists — handled below by reading
    /// that existing event back and confirming its marker matches, rather
    /// than creating a duplicate.
    public func createManagedEvent(
        accessToken: String,
        calendarID: String,
        request managed: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        let eventID = try deterministicGoogleEventID(
            mirrorKey: managed.provenance.mirrorKey
        )
        let endpoint = eventCollectionURL(calendarID: calendarID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try managedEventBody(
            managed,
            eventID: eventID
        )
        do {
            let response = try await send(request: request, accessToken: accessToken)
            return try managedWriteResult(response)
        } catch ProviderFailure.httpStatus(409) {
            let existingURL = endpoint.appendingPathComponent(eventID)
            let response = try await send(url: existingURL, accessToken: accessToken)
            let existing: GoogleEvent = try decode(response)
            let marker = OwnershipMarkerCodec.marker(
                fields: existing.extendedProperties?.privateValues
            )
            // The ID collision only counts as "this create already
            // happened" if the existing event's marker proves it's the same
            // logical write — anything else (a genuine ID collision, or an
            // event this create doesn't actually own) is treated as failure
            // rather than silently adopted.
            guard marker.status == .parsed,
                  marker.provenance == managed.provenance else {
                throw ProviderFailure.invalidResponse
            }
            return ManagedEventWriteResult(
                providerEventID: existing.id,
                providerVersion: existing.etag ?? response.headers["etag"]
            )
        }
    }

    public func updateManagedEvent(
        accessToken: String,
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request managed: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        let endpoint = eventCollectionURL(calendarID: calendarID)
            .appendingPathComponent(providerEventID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        expectedVersion.map { request.setValue($0, forHTTPHeaderField: "If-Match") }
        request.httpBody = try managedEventBody(managed, eventID: nil)
        let response = try await send(request: request, accessToken: accessToken)
        return try managedWriteResult(response)
    }

    public func deleteManagedEvent(
        accessToken: String,
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) async throws {
        let endpoint = eventCollectionURL(calendarID: calendarID)
            .appendingPathComponent(providerEventID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        expectedVersion.map { request.setValue($0, forHTTPHeaderField: "If-Match") }
        _ = try await send(request: request, accessToken: accessToken)
    }

    private func send(url: URL, accessToken: String) async throws -> HTTPResponse {
        let request = URLRequest(url: url)
        return try await send(request: request, accessToken: accessToken)
    }

    // Maps Google's HTTP status codes to the shared `ProviderFailure`
    // vocabulary once, here, so every call site above gets the same
    // treatment of expired credentials (401), an expired sync token (410,
    // Google's specific code for "your cursor is too old"), and throttling
    // (429/5xx) without repeating this switch everywhere.
    private func send(request original: URLRequest, accessToken: String) async throws -> HTTPResponse {
        var request = original
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return response
        case 401:
            throw ProviderFailure.authorizationRequired
        case 410:
            throw ProviderFailure.cursorExpired
        case 429, 500...599:
            throw ProviderFailure.temporaryFailure(
                retryAfterSeconds: response.headers["retry-after"].flatMap(Int.init)
            )
        default:
            throw ProviderFailure.httpStatus(response.statusCode)
        }
    }

    private func decode<Value: Decodable>(_ response: HTTPResponse) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: response.body)
        } catch {
            throw ProviderFailure.invalidResponse
        }
    }

    private func eventCollectionURL(calendarID: String) -> URL {
        baseURL
            .appendingPathComponent("calendars", isDirectory: true)
            .appendingPathComponent(calendarID, isDirectory: true)
            .appendingPathComponent("events")
    }

    // The ownership marker's fields are written into Google's
    // `extendedProperties.private` bag, which Google Calendar reserves for
    // exactly this purpose (app-private metadata invisible to the user and
    // to other apps) rather than overloading a user-facing field.
    private func managedEventBody(
        _ managed: ManagedEventWriteRequest,
        eventID: String?
    ) throws -> Data {
        let payload = managed.payload
        let start: [String: String]
        let end: [String: String]
        if payload.isAllDay {
            start = ["date": GoogleDate.dateOnly(payload.startsAt)]
            end = ["date": GoogleDate.dateOnly(payload.endsAt)]
        } else {
            start = ["dateTime": RFC3339.string(from: payload.startsAt)]
            end = ["dateTime": RFC3339.string(from: payload.endsAt)]
        }
        let provenance = managed.provenance
        var object: [String: Any] = [
            "summary": payload.title ?? "",
            "start": start,
            "end": end,
            "transparency": payload.availability == "free" ? "transparent" : "opaque",
            "reminders": ["useDefault": false],
            "extendedProperties": [
                "private": [
                    "calopodSchema": String(provenance.schemaVersion),
                    "configurationID": provenance.configurationID,
                    "armID": provenance.armID,
                    "mirrorKey": provenance.mirrorKey,
                    "sourceKeyHash": provenance.sourceKeyHash,
                    "ruleMode": provenance.ruleMode.rawValue,
                    "ownershipKeyID": provenance.ownershipKeyID,
                    "authenticationTag": provenance.authenticationTag,
                    "desiredFingerprint": managed.desiredFingerprint,
                ],
            ],
        ]
        if let eventID {
            object["id"] = eventID
        }
        if let isPrivate = payload.isPrivate {
            object["visibility"] = isPrivate ? "private" : "default"
        }
        if let location = payload.location {
            object["location"] = location
        }
        if let notes = payload.notes {
            object["description"] = notes
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func managedWriteResult(_ response: HTTPResponse) throws -> ManagedEventWriteResult {
        let event: GoogleManagedEventResponse = try decode(response)
        return ManagedEventWriteResult(
            providerEventID: event.id,
            providerVersion: event.etag ?? response.headers["etag"]
        )
    }

}

private struct GoogleManagedEventResponse: Decodable {
    let id: String
    let etag: String?
}

private enum GoogleDate {
    static func dateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private func decodeBase32(_ value: String) -> Data? {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    let indices = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
    var bytes: [UInt8] = []
    var buffer: UInt32 = 0
    var bitCount = 0
    for character in value.lowercased() {
        guard let index = indices[character] else { return nil }
        buffer = (buffer << 5) | UInt32(index)
        bitCount += 5
        if bitCount >= 8 {
            bitCount -= 8
            bytes.append(UInt8((buffer >> UInt32(bitCount)) & 0xff))
            buffer &= bitCount == 0 ? 0 : (1 << UInt32(bitCount)) - 1
        }
    }
    return Data(bytes)
}

private func encodeBase32Hex(_ data: Data) -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
    var result = ""
    var buffer: UInt32 = 0
    var bitCount = 0
    for byte in data {
        buffer = (buffer << 8) | UInt32(byte)
        bitCount += 8
        while bitCount >= 5 {
            bitCount -= 5
            result.append(alphabet[Int((buffer >> UInt32(bitCount)) & 31)])
        }
        buffer &= bitCount == 0 ? 0 : (1 << UInt32(bitCount)) - 1
    }
    if bitCount > 0 {
        result.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 31)])
    }
    return result
}

private struct CalendarListResponse: Decodable {
    let items: [CalendarListItem]
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([CalendarListItem].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct CalendarListItem: Decodable {
    let id: String
    let summary: String?
    let timeZone: String?
    let accessRole: String
    let primary: Bool?
}

private struct EventListResponse: Decodable {
    let items: [GoogleEvent]
    let nextPageToken: String?
    let nextSyncToken: String?
    let timeZone: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
        case nextSyncToken
        case timeZone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([GoogleEvent].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        nextSyncToken = try container.decodeIfPresent(String.self, forKey: .nextSyncToken)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
    }
}

private struct GoogleEvent: Decodable {
    let id: String
    let etag: String?
    let recurringEventID: String?
    let recurrence: [String]?
    let originalStartTime: GoogleEventTime?
    let start: GoogleEventTime?
    let end: GoogleEventTime?
    let status: String?
    let transparency: String?
    let visibility: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let conferenceData: GoogleConferenceData?
    let organizer: GooglePerson?
    let attendees: [GoogleAttendee]?
    let attendeesOmitted: Bool?
    let created: String?
    let updated: String?
    let extendedProperties: GoogleExtendedProperties?

    enum CodingKeys: String, CodingKey {
        case id
        case etag
        case recurringEventID = "recurringEventId"
        case recurrence
        case originalStartTime
        case start
        case end
        case status
        case transparency
        case visibility
        case summary
        case description
        case location
        case htmlLink
        case hangoutLink
        case conferenceData
        case organizer
        case attendees
        case attendeesOmitted
        case created
        case updated
        case extendedProperties
    }

    func providerEvent(
        connectionID: String,
        calendarID: String,
        fallbackTimeZone: TimeZone,
        responseIdentityScope: ResponseIdentityScope
    ) -> ProviderEvent {
        ProviderEvent(
            provider: "google",
            connectionID: connectionID,
            calendarID: calendarID,
            eventID: id,
            seriesID: recurringEventID,
            originalStart: originalStartTime?.identity,
            start: start?.date(fallbackTimeZone: fallbackTimeZone),
            end: end?.date(fallbackTimeZone: fallbackTimeZone),
            isAllDay: start?.dateOnly != nil,
            availability: transparency == "transparent" ? .free : .busy,
            isCancelled: status == "cancelled",
            isPrivate: visibility == "private" || visibility == "confidential",
            title: summary,
            updatedAt: updated.flatMap(RFC3339.date(from:)),
            isManagedMirror: OwnershipMarkerCodec.marker(
                fields: extendedProperties?.privateValues
            ).status != .absent,
            location: location,
            notes: description,
            // Prefers an actual video-call link over the generic event page,
            // so EventKit's "join" affordance (which recognizes a meeting
            // link in notes) has something useful to act on; htmlLink is
            // only a fallback when the event has no conferencing at all.
            url: hangoutLink ?? conferenceData?.videoURI ?? htmlLink,
            organizer: organizer?.participant,
            attendees: (attendees ?? []).map(\.participant),
            responseMetadata: currentUserResponse(scope: responseIdentityScope)
        )
    }

    private func currentUserResponse(scope: ResponseIdentityScope) -> EventResponse {
        guard scope == .authenticatedUser else {
            return EventResponse(state: .unknown, limits: [.identityUnverified, .timestampUnavailable],
                                 unavailableReasons: [.identityUnverified, .actionsNotImplemented])
        }
        if organizer?.isSelf == true {
            return EventResponse(state: .organizer, evidence: .googleSelf,
                                 limits: [.timestampUnavailable], unavailableReasons: [.notAnInvitation])
        }
        let current = (attendees ?? []).filter { $0.isSelf == true }
        guard current.count == 1 else {
            return EventResponse(state: .unknown,
                                 limits: [current.isEmpty ? .missingParticipant : .ambiguousParticipant,
                                          .timestampUnavailable],
                                 unavailableReasons: [.identityUnverified, .actionsNotImplemented])
        }
        if current[0].isOrganizer == true {
            return EventResponse(state: .organizer, evidence: .googleSelf,
                                 limits: [.timestampUnavailable], unavailableReasons: [.notAnInvitation])
        }
        let state: EventResponseState
        switch current[0].responseStatus {
        case "needsAction": state = .needsResponse
        case "accepted": state = .accepted
        case "tentative": state = .tentative
        case "declined": state = .declined
        default: state = .unknown
        }
        var limits: [ResponseLimit] = [.timestampUnavailable]
        if state == .unknown { limits.append(.unsupportedStatus) }
        if attendeesOmitted == true { limits.append(.incompleteParticipants) }
        return EventResponse(state: state, evidence: .googleSelf, limits: limits,
                             unavailableReasons: state == .unknown
                                 ? [.unsupportedResponse, .actionsNotImplemented] : [.actionsNotImplemented])
    }

    func managedSnapshot(fallbackTimeZone: TimeZone) -> ManagedEventSnapshot {
        let decoded = OwnershipMarkerCodec.marker(fields: extendedProperties?.privateValues)
        let startsAt = start?.date(fallbackTimeZone: fallbackTimeZone)
        let endsAt = end?.date(fallbackTimeZone: fallbackTimeZone)
        let payload: DesiredEventPayload?
        if status != "cancelled", let startsAt, let endsAt, startsAt < endsAt {
            payload = DesiredEventPayload(
                startsAt: startsAt,
                endsAt: endsAt,
                isAllDay: start?.dateOnly != nil,
                availability: transparency == "transparent" ? "free" : "busy",
                title: summary,
                isPrivate: decoded.provenance?.ruleMode == .busy
                    ? nil
                    : visibility == "private" || visibility == "confidential",
                location: location,
                notes: description
            )
        } else {
            payload = nil
        }
        return ManagedEventSnapshot(
            providerEventID: id,
            providerVersion: etag,
            payload: payload,
            markerStatus: decoded.status,
            provenance: decoded.provenance,
            createdAt: created.flatMap(RFC3339.date(from:)),
            // True when this event's actual ID matches the deterministic ID
            // `createManagedEvent` would have used — i.e. it really is the
            // event Calopod originally created for this mirror, not a
            // provider-side copy with a different ID that happens to carry
            // a matching marker.
            isProviderPreferredIdentity: decoded.provenance.flatMap {
                try? deterministicGoogleEventID(mirrorKey: $0.mirrorKey)
            } == id
        )
    }
}

private struct GooglePerson: Decodable {
    let isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case isSelf = "self"
        case email, displayName
    }
    let email: String?
    let displayName: String?

    var participant: EventParticipant {
        EventParticipant(name: displayName, emailAddress: email)
    }
}

private struct GoogleAttendee: Decodable {
    let isSelf: Bool?
    let isOrganizer: Bool?

    enum CodingKeys: String, CodingKey {
        case isSelf = "self"
        case email, displayName, responseStatus
        case isOrganizer = "organizer"
    }
    let email: String?
    let displayName: String?
    let responseStatus: String?

    var participant: EventParticipant {
        EventParticipant(
            name: displayName,
            emailAddress: email,
            status: responseStatus
        )
    }
}

private struct GoogleConferenceData: Decodable {
    let entryPoints: [GoogleConferenceEntryPoint]?

    var videoURI: String? {
        entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
    }
}

private struct GoogleConferenceEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

private func deterministicGoogleEventID(mirrorKey: String) throws -> String {
    guard let bytes = decodeBase32(mirrorKey) else {
        throw ProviderFailure.invalidResponse
    }
    return encodeBase32Hex(bytes)
}

private struct GoogleExtendedProperties: Decodable {
    let privateValues: [String: String]?

    enum CodingKeys: String, CodingKey {
        case privateValues = "private"
    }
}

private struct GoogleEventTime: Decodable {
    let dateTime: String?
    let dateOnly: String?
    let timeZone: String?

    enum CodingKeys: String, CodingKey {
        case dateTime
        case dateOnly = "date"
        case timeZone
    }

    var identity: String? {
        dateTime ?? dateOnly
    }

    func date(fallbackTimeZone: TimeZone) -> Date? {
        if let dateTime {
            return RFC3339.date(from: dateTime)
        }
        guard let dateOnly else {
            return nil
        }
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? fallbackTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = dateOnly.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

private enum RFC3339 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension RSVPDecision {
    var googleStatus: String {
        switch self {
        case .yes: "accepted"
        case .no: "declined"
        case .maybe: "tentative"
        }
    }
}
