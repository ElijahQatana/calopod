import CalopodDomain
import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A calendar as Microsoft Graph's calendars endpoint reports it.
public struct MicrosoftCalendar: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let isDefault: Bool
    public let canEdit: Bool
    public let hexColor: String?

    public init(id: String, name: String?, isDefault: Bool, canEdit: Bool, hexColor: String? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.canEdit = canEdit
        self.hexColor = hexColor
    }
}

/// Thin client over Microsoft Graph v1.0. Like the Google client it holds no auth state.
public struct MicrosoftGraphClient: Sendable {
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func calendars(accessToken: String) async throws -> [MicrosoftCalendar] {
        var calendars: [MicrosoftCalendar] = []
        var nextURL: URL? = baseURL.appendingPathComponent("me/calendars")

        while let url = nextURL {
            let response = try await send(url: url, accessToken: accessToken, followsCursor: false)
            let page: MicrosoftCalendarList = try decode(response)
            calendars.append(contentsOf: page.value.map {
                MicrosoftCalendar(
                    id: $0.id,
                    name: $0.name,
                    isDefault: $0.isDefaultCalendar ?? false,
                    canEdit: $0.canEdit ?? false,
                    hexColor: ProviderColor.hex($0.hexColor)
                )
            })
            nextURL = try page.nextLink.map(validatedLink)
        }
        return calendars
    }

    public func events(
        accessToken: String,
        connectionID: String,
        calendarID: String,
        from start: Date,
        through end: Date,
        deltaLink: String? = nil,
        responseIdentityScope: ResponseIdentityScope = .unverified
    ) async throws -> ProviderEventPage {
        // A stored delta link resumes the last fetch. One that isn't a valid URL is treated as
        // expired, so we fall back to a full read.
        let initialURL: URL
        let followsCursor: Bool
        if let deltaLink {
            guard let parsed = URL(string: deltaLink) else {
                throw ProviderFailure.cursorExpired
            }
            initialURL = try validatedLink(parsed)
            followsCursor = true
        } else {
            let endpoint = baseURL
                .appendingPathComponent("me", isDirectory: true)
                .appendingPathComponent("calendars", isDirectory: true)
                .appendingPathComponent(calendarID, isDirectory: true)
                .appendingPathComponent("calendarView", isDirectory: true)
                .appendingPathComponent("delta")
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "startDateTime", value: MicrosoftDate.string(from: start)),
                URLQueryItem(name: "endDateTime", value: MicrosoftDate.string(from: end)),
            ]
            guard let url = components?.url else {
                throw ProviderFailure.invalidResponse
            }
            initialURL = url
            followsCursor = false
        }

        var events: [ProviderEvent] = []
        var nextURL: URL? = initialURL
        var nextDeltaLink: String?
        var isFollowingCursor = followsCursor

        while let url = nextURL {
            let response = try await send(
                url: url,
                accessToken: accessToken,
                followsCursor: isFollowingCursor
            )
            let page: MicrosoftEventList = try decode(response)
            events.append(contentsOf: page.value.map {
                $0.providerEvent(connectionID: connectionID, calendarID: calendarID,
                                 responseIdentityScope: responseIdentityScope)
            })
            nextURL = try page.nextLink.map(validatedLink)
            if let delta = page.deltaLink {
                nextDeltaLink = try validatedLink(delta).absoluteString
            }
            isFollowingCursor = true
        }

        return ProviderEventPage(events: events, nextSyncToken: nextDeltaLink)
    }

    public func rsvpSnapshot(accessToken: String, target: RSVPTarget,
                             authorization: RSVPAuthorization) async throws -> RSVPEventSnapshot {
        guard target.provider == "microsoft", !target.eventID.isEmpty, !target.calendarID.isEmpty,
              !target.eventID.contains("/"), !target.calendarID.contains("/") else {
            throw RSVPActionError.unavailable(.identity)
        }
        var components = URLComponents(url: eventCollectionURL(calendarID: target.calendarID)
            .appendingPathComponent(target.eventID), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "$expand", value: "extensions")]
        guard let url = components?.url else { throw RSVPActionError.unavailable(.unsupported) }
        let response = try await send(url: url, accessToken: accessToken, followsCursor: false)
        let event: MicrosoftEvent = try decode(response)
        guard event.id == target.eventID, event.seriesMasterID == target.seriesID,
              event.originalStart == target.originalStart else { throw RSVPActionError.stale }
        let normalized = event.providerEvent(connectionID: target.connectionID, calendarID: target.calendarID,
                                             responseIdentityScope: authorization.identityScope)
        var reasons: [RSVPUnavailableReason] = []
        if authorization.identityScope != .authenticatedUser { reasons.append(.identityUnverified) }
        if !authorization.canRespond { reasons.append(.permissionUnverified) }
        if normalized.isManagedMirror { reasons.append(.managedMirror) }
        if normalized.isCancelled || event.isOrganizer != false || event.attendees?.isEmpty != false {
            reasons.append(.notAnInvitation)
        }
        if [.unknown, .notApplicable, .organizer].contains(normalized.currentUserResponse.state) {
            reasons.append(.unsupportedResponse)
        }
        let single = event.type == "singleInstance" && event.seriesMasterID == nil && event.originalStart == nil
        let occurrence = ["occurrence", "exception"].contains(event.type)
            && event.seriesMasterID != nil && event.originalStart != nil
        if !single && !occurrence { reasons.append(.unsupportedScope) }
        let version = event.etag ?? event.changeKey ?? response.headers["etag"]
        if version?.isEmpty != false { reasons.append(.staleRevision) }
        return RSVPEventSnapshot(target: target, event: normalized, version: version,
            capability: reasons.isEmpty ? RSVPActionCapability(supportedScopes: [.occurrence])
                : RSVPActionCapability(unavailableReasons: reasons),
            notification: .microsoftOrganizer, concurrency: .preflightOnly)
    }

    public func submitRSVP(accessToken: String, intent: RSVPActionIntent,
                           authorization: RSVPAuthorization) async throws {
        let snapshot = try await rsvpSnapshot(accessToken: accessToken, target: intent.target, authorization: authorization)
        try snapshot.validate(intent)
        let url = eventCollectionURL(calendarID: intent.target.calendarID)
            .appendingPathComponent(intent.target.eventID).appendingPathComponent(intent.decision.microsoftAction)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Graph's response actions do not document atomic If-Match support.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sendResponse": true])
        do { _ = try await send(request: request, accessToken: accessToken, followsCursor: false) }
        catch { throw RSVPActionError.writeFailure(error) }
    }

    public func reconcileRSVP(accessToken: String, record: RSVPActionRecord,
                              authorization: RSVPAuthorization) async throws -> RSVPActionOutcome {
        do {
            let snapshot = try await rsvpSnapshot(accessToken: accessToken, target: record.intent.target, authorization: authorization)
            return RSVPReadback.outcome(record, snapshot: snapshot)
        } catch ProviderFailure.httpStatus(404) {
            return RSVPReadback.missing(record)
        }
    }

    public func managedEvents(
        accessToken: String,
        calendarID: String,
        from start: Date,
        through end: Date
    ) async throws -> [ManagedEventSnapshot] {
        let endpoint = baseURL
            .appendingPathComponent("me", isDirectory: true)
            .appendingPathComponent("calendars", isDirectory: true)
            .appendingPathComponent(calendarID, isDirectory: true)
            .appendingPathComponent("calendarView")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "startDateTime", value: MicrosoftDate.string(from: start)),
            URLQueryItem(name: "endDateTime", value: MicrosoftDate.string(from: end)),
            URLQueryItem(name: "$expand", value: "extensions"),
        ]
        guard let initialURL = components?.url else { throw ProviderFailure.invalidResponse }

        var snapshots: [ManagedEventSnapshot] = []
        var nextURL: URL? = initialURL
        while let url = nextURL {
            let response = try await send(url: url, accessToken: accessToken, followsCursor: false)
            let page: MicrosoftEventList = try decode(response)
            snapshots.append(contentsOf: page.value.map(\.managedSnapshot))
            nextURL = try page.nextLink.map(validatedLink)
        }
        return snapshots
    }

    public func createManagedEvent(
        accessToken: String,
        calendarID: String,
        request managed: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        var request = URLRequest(url: eventCollectionURL(calendarID: calendarID))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try managedEventBody(managed, includeExtension: true)
        let response = try await send(
            request: request,
            accessToken: accessToken,
            followsCursor: false
        )
        return try managedWriteResult(response)
    }

    public func updateManagedEvent(
        accessToken: String,
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request managed: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        let eventURL = eventCollectionURL(calendarID: calendarID)
            .appendingPathComponent(providerEventID)
        var eventRequest = URLRequest(url: eventURL)
        eventRequest.httpMethod = "PATCH"
        eventRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        expectedVersion.map { eventRequest.setValue($0, forHTTPHeaderField: "If-Match") }
        eventRequest.httpBody = try managedEventBody(managed, includeExtension: false)
        let eventResponse = try await send(
            request: eventRequest,
            accessToken: accessToken,
            followsCursor: false
        )

        // On update the marker goes in a separate PATCH to the extension; on create it is embedded
        // in the event body.
        let extensionURL = eventURL
            .appendingPathComponent("extensions")
            .appendingPathComponent("com.calopod.managed")
        var extensionRequest = URLRequest(url: extensionURL)
        extensionRequest.httpMethod = "PATCH"
        extensionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        extensionRequest.httpBody = try JSONSerialization.data(
            withJSONObject: managedExtension(managed),
            options: [.sortedKeys]
        )
        _ = try await send(
            request: extensionRequest,
            accessToken: accessToken,
            followsCursor: false
        )
        return try managedWriteResult(eventResponse)
    }

    public func deleteManagedEvent(
        accessToken: String,
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) async throws {
        let eventURL = eventCollectionURL(calendarID: calendarID)
            .appendingPathComponent(providerEventID)
        var request = URLRequest(url: eventURL)
        request.httpMethod = "DELETE"
        expectedVersion.map { request.setValue($0, forHTTPHeaderField: "If-Match") }
        _ = try await send(request: request, accessToken: accessToken, followsCursor: false)
    }

    private func send(
        url: URL,
        accessToken: String,
        followsCursor: Bool
    ) async throws -> HTTPResponse {
        let request = URLRequest(url: url)
        return try await send(
            request: request,
            accessToken: accessToken,
            followsCursor: followsCursor
        )
    }

    // `IdType="ImmutableId"` keeps event IDs stable across moves, so a stored mapping keeps
    // resolving.
    // `followsCursor` matters for status mapping: a 404 means "delta cursor gone" only when
    // following one.
    private func send(
        request original: URLRequest,
        accessToken: String,
        followsCursor: Bool
    ) async throws -> HTTPResponse {
        var request = original
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "IdType=\"ImmutableId\", outlook.timezone=\"UTC\", outlook.body-content-type=\"text\", odata.maxpagesize=1000",
            forHTTPHeaderField: "Prefer"
        )
        let response = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return response
        case 401:
            throw ProviderFailure.authorizationRequired
        case 403:
            throw ProviderFailure.accountPolicyRequired
        case 404 where followsCursor, 410:
            throw ProviderFailure.cursorExpired
        case 429, 500...599:
            throw ProviderFailure.temporaryFailure(
                retryAfterSeconds: response.headers["retry-after"].flatMap(Int.init)
            )
        default:
            throw ProviderFailure.httpStatus(response.statusCode)
        }
    }

    // Next and delta links are opaque, so check they still point at the Graph host before fetching.
    private func validatedLink(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port else {
            throw ProviderFailure.invalidResponse
        }
        return url
    }

    private func validatedLink(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ProviderFailure.invalidResponse
        }
        return try validatedLink(url)
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
            .appendingPathComponent("me", isDirectory: true)
            .appendingPathComponent("calendars", isDirectory: true)
            .appendingPathComponent(calendarID, isDirectory: true)
            .appendingPathComponent("events")
    }

    private func managedEventBody(
        _ managed: ManagedEventWriteRequest,
        includeExtension: Bool
    ) throws -> Data {
        let payload = managed.payload
        // Graph wants all-day events to run midnight to midnight in the stated zone.
        let start: String
        let end: String
        if payload.isAllDay {
            let days = AllDayDate.days(
                startsAt: payload.startsAt,
                endsAt: payload.endsAt,
                timeZoneIdentifier: payload.timeZoneIdentifier
            )
            start = "\(days.start)T00:00:00.0000000"
            end = "\(days.end)T00:00:00.0000000"
        } else {
            start = MicrosoftDate.string(from: payload.startsAt)
            end = MicrosoftDate.string(from: payload.endsAt)
        }
        var object: [String: Any] = [
            "subject": payload.title ?? "",
            "start": ["dateTime": start, "timeZone": "UTC"],
            "end": ["dateTime": end, "timeZone": "UTC"],
            "isAllDay": payload.isAllDay,
            "showAs": microsoftAvailability(payload.availability),
            "isReminderOn": false,
            "isOnlineMeeting": false,
            "responseRequested": false,
        ]
        if includeExtension {
            object["transactionId"] = managed.provenance.mirrorKey
        }
        if let isPrivate = payload.isPrivate {
            object["sensitivity"] = isPrivate ? "private" : "normal"
        }
        if let location = payload.location {
            object["location"] = ["displayName": location]
        } else if !includeExtension {
            object["location"] = ["displayName": ""]
        }
        if let notes = payload.notes {
            object["body"] = ["contentType": "text", "content": notes]
        } else if !includeExtension {
            object["body"] = ["contentType": "text", "content": ""]
        }
        if includeExtension {
            object["extensions"] = [managedExtension(managed)]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func managedExtension(_ managed: ManagedEventWriteRequest) -> [String: Any] {
        let provenance = managed.provenance
        return [
            "@odata.type": "microsoft.graph.openTypeExtension",
            "extensionName": "com.calopod.managed",
            "schemaVersion": String(provenance.schemaVersion),
            "configurationID": provenance.configurationID,
            "armID": provenance.armID,
            "mirrorKey": provenance.mirrorKey,
            "sourceKeyHash": provenance.sourceKeyHash,
            "ruleMode": provenance.ruleMode.rawValue,
            "ownershipKeyID": provenance.ownershipKeyID,
            "authenticationTag": provenance.authenticationTag,
            "desiredFingerprint": managed.desiredFingerprint,
        ]
    }

    private func managedWriteResult(_ response: HTTPResponse) throws -> ManagedEventWriteResult {
        let event: MicrosoftManagedEventResponse = try decode(response)
        return ManagedEventWriteResult(
            providerEventID: event.id,
            providerVersion: event.changeKey ?? event.etag ?? response.headers["etag"]
        )
    }

    private func microsoftAvailability(_ value: String) -> String {
        switch value {
        case "free": "free"
        case "tentative": "tentative"
        case "unavailable", "out-of-office": "oof"
        default: "busy"
        }
    }
}

private struct MicrosoftManagedEventResponse: Decodable {
    let id: String
    let changeKey: String?
    let etag: String?

    enum CodingKeys: String, CodingKey {
        case id
        case changeKey
        case etag = "@odata.etag"
    }
}

private struct MicrosoftCalendarList: Decodable {
    let value: [MicrosoftCalendarItem]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct MicrosoftCalendarItem: Decodable {
    let id: String
    let name: String?
    let isDefaultCalendar: Bool?
    let canEdit: Bool?
    let hexColor: String?
}

private struct MicrosoftEventList: Decodable {
    let value: [MicrosoftEvent]
    let nextLink: String?
    let deltaLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

private struct MicrosoftEvent: Decodable {
    let id: String
    let changeKey: String?
    let etag: String?
    let seriesMasterID: String?
    let type: String?
    let originalStart: String?
    let start: MicrosoftEventTime?
    let end: MicrosoftEventTime?
    let isAllDay: Bool?
    let isCancelled: Bool?
    let showAs: String?
    let sensitivity: String?
    let subject: String?
    let bodyPreview: String?
    let body: MicrosoftEventBody?
    let location: MicrosoftLocation?
    let webLink: String?
    let onlineMeetingUrl: String?
    let onlineMeeting: MicrosoftOnlineMeeting?
    let organizer: MicrosoftRecipient?
    let attendees: [MicrosoftAttendee]?
    let responseStatus: MicrosoftResponseStatus?
    let isOrganizer: Bool?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    let removed: MicrosoftRemoved?
    let extensions: [MicrosoftManagedExtension]?

    enum CodingKeys: String, CodingKey {
        case id
        case changeKey
        case etag = "@odata.etag"
        case seriesMasterID = "seriesMasterId"
        case type
        case originalStart
        case start
        case end
        case isAllDay
        case isCancelled
        case showAs
        case sensitivity
        case subject
        case bodyPreview
        case body
        case location
        case webLink
        case onlineMeetingUrl
        case onlineMeeting
        case organizer
        case attendees
        case responseStatus
        case isOrganizer
        case createdDateTime
        case lastModifiedDateTime
        case removed = "@removed"
        case extensions
    }

    func providerEvent(connectionID: String, calendarID: String,
                       responseIdentityScope: ResponseIdentityScope) -> ProviderEvent {
        ProviderEvent(
            provider: "microsoft",
            connectionID: connectionID,
            calendarID: calendarID,
            eventID: id,
            seriesID: seriesMasterID,
            originalStart: originalStart,
            start: start?.date,
            end: end?.date,
            isAllDay: isAllDay ?? false,
            availability: availability,
            isCancelled: removed != nil || isCancelled == true,
            isPrivate: sensitivity == "private"
                || sensitivity == "personal"
                || sensitivity == "confidential",
            title: subject,
            updatedAt: lastModifiedDateTime.flatMap { MicrosoftDate.date(from: $0) },
            isManagedMirror: extensions?.contains(where: \.isCalopodMarker) == true,
            location: location?.displayName,
            notes: plainTextBody,
            url: onlineMeeting?.joinUrl ?? onlineMeetingUrl ?? webLink,
            organizer: organizer?.participant,
            attendees: (attendees ?? []).map(\.participant),
            responseMetadata: currentUserResponse(scope: responseIdentityScope),
            tombstoneEvidence: removed != nil ? .unconfirmed : nil
        )
    }

    private func currentUserResponse(scope: ResponseIdentityScope) -> EventResponse {
        guard scope == .authenticatedUser else {
            return EventResponse(state: .unknown, limits: [.identityUnverified],
                                 unavailableReasons: [.identityUnverified, .actionsNotImplemented])
        }
        let state: EventResponseState
        if isOrganizer == true {
            state = .organizer
        } else {
            switch responseStatus?.response {
            case "organizer" where isOrganizer != false: state = .organizer
            case "notResponded": state = .needsResponse
            case "accepted": state = .accepted
            case "tentativelyAccepted": state = .tentative
            case "declined": state = .declined
            default: state = .unknown
            }
        }
        // Graph can use a year-one sentinel when no response time is known.
        let timestamp = responseStatus?.time.flatMap { value -> Date? in
            guard !value.hasPrefix("0001-") else { return nil }
            return MicrosoftDate.date(from: value)
        }
        var limits: [ResponseLimit] = timestamp == nil ? [.timestampUnavailable] : []
        if state == .unknown { limits.append(.unsupportedStatus) }
        return EventResponse(state: state, respondedAt: timestamp, evidence: .microsoftEvent,
                             limits: limits, unavailableReasons: state == .organizer ? [.notAnInvitation]
                                 : state == .unknown ? [.unsupportedResponse, .actionsNotImplemented]
                                 : [.actionsNotImplemented])
    }

    var managedSnapshot: ManagedEventSnapshot {
        let markerExtension = extensions?.first(where: { $0.isCalopodMarker })
        let decoded = OwnershipMarkerCodec.marker(fields: markerExtension?.markerFields)
        // An extension that is present but empty is a corrupted marker, so report `.invalid` rather
        // than unmanaged.
        let markerStatus: ManagedEventMarkerStatus = if markerExtension != nil,
                                                        decoded.status == .absent {
            .invalid
        } else {
            decoded.status
        }
        let startsAt = start?.date
        let endsAt = end?.date
        let payload: DesiredEventPayload?
        if removed == nil, isCancelled != true,
           let startsAt, let endsAt, startsAt < endsAt {
            payload = DesiredEventPayload(
                startsAt: startsAt,
                endsAt: endsAt,
                isAllDay: isAllDay ?? false,
                availability: availability.rawValue,
                title: subject,
                isPrivate: decoded.provenance?.ruleMode == .busy
                    ? nil
                    : sensitivity == "private"
                        || sensitivity == "personal"
                        || sensitivity == "confidential",
                location: location?.displayName,
                notes: plainTextBody,
                // Reads ask for UTC, so an all-day event's day is its UTC day.
                timeZoneIdentifier: isAllDay == true ? "UTC" : nil
            )
        } else {
            payload = nil
        }
        return ManagedEventSnapshot(
            providerEventID: id,
            providerVersion: changeKey ?? etag,
            payload: payload,
            markerStatus: markerStatus,
            provenance: decoded.provenance,
            createdAt: createdDateTime.flatMap { MicrosoftDate.date(from: $0) }
        )
    }

    private var availability: ProviderAvailability {
        switch showAs {
        case "free": .free
        case "tentative", "workingElsewhere": .tentative
        case "oof": .unavailable
        case "busy": .busy
        default: .busy
        }
    }

    private var plainTextBody: String? {
        if body?.contentType?.lowercased() == "text",
           let content = body?.content,
           !content.isEmpty {
            return content
        }
        guard let bodyPreview, !bodyPreview.isEmpty else { return nil }
        return bodyPreview
    }
}

private struct MicrosoftEventBody: Decodable {
    let contentType: String?
    let content: String?
}

private struct MicrosoftLocation: Decodable {
    let displayName: String?
}

private struct MicrosoftOnlineMeeting: Decodable {
    let joinUrl: String?
}

private struct MicrosoftRecipient: Decodable {
    let emailAddress: MicrosoftEmailAddress?

    var participant: EventParticipant {
        EventParticipant(
            name: emailAddress?.name,
            emailAddress: emailAddress?.address
        )
    }
}

private struct MicrosoftAttendee: Decodable {
    let emailAddress: MicrosoftEmailAddress?
    let status: MicrosoftResponseStatus?

    var participant: EventParticipant {
        EventParticipant(
            name: emailAddress?.name,
            emailAddress: emailAddress?.address,
            status: status?.response
        )
    }
}

private struct MicrosoftEmailAddress: Decodable {
    let name: String?
    let address: String?
}

private struct MicrosoftResponseStatus: Decodable {
    let response: String?
    let time: String?
}

private struct MicrosoftManagedExtension: Decodable {
    let id: String?
    let extensionName: String?
    let schemaVersion: String?
    let configurationID: String?
    let armID: String?
    let mirrorKey: String?
    let sourceKeyHash: String?
    let ruleMode: String?
    let ownershipKeyID: String?
    let authenticationTag: String?

    var isCalopodMarker: Bool {
        extensionName == "com.calopod.managed"
            || id?.hasSuffix(".com.calopod.managed") == true
    }

    var markerFields: [String: String] {
        [
            "calopodSchema": schemaVersion,
            "configurationID": configurationID,
            "armID": armID,
            "mirrorKey": mirrorKey,
            "sourceKeyHash": sourceKeyHash,
            "ruleMode": ruleMode,
            "ownershipKeyID": ownershipKeyID,
            "authenticationTag": authenticationTag,
        ].compactMapValues { $0 }
    }
}

private struct MicrosoftRemoved: Decodable {
    let reason: String?
}

private struct MicrosoftEventTime: Decodable {
    let dateTime: String
    let timeZone: String?

    var date: Date? {
        MicrosoftDate.date(from: dateTime, timeZone: timeZone)
    }
}

private enum MicrosoftDate {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String, timeZone: String? = nil) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private extension RSVPDecision {
    var microsoftAction: String {
        switch self {
        case .yes: "accept"
        case .no: "decline"
        case .maybe: "tentativelyAccept"
        }
    }
}
