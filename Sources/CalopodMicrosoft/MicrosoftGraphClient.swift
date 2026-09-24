import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MicrosoftCalendar: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let isDefault: Bool
    public let canEdit: Bool

    public init(id: String, name: String?, isDefault: Bool, canEdit: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.canEdit = canEdit
    }
}

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
                    canEdit: $0.canEdit ?? false
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
        deltaLink: String? = nil
    ) async throws -> ProviderEventPage {
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
                $0.providerEvent(connectionID: connectionID, calendarID: calendarID)
            })
            nextURL = try page.nextLink.map(validatedLink)
            if let delta = page.deltaLink {
                nextDeltaLink = try validatedLink(delta).absoluteString
            }
            isFollowingCursor = true
        }

        return ProviderEventPage(events: events, nextSyncToken: nextDeltaLink)
    }

    private func send(
        url: URL,
        accessToken: String,
        followsCursor: Bool
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "outlook.timezone=\"UTC\", odata.maxpagesize=1000",
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
    let seriesMasterID: String?
    let originalStart: String?
    let start: MicrosoftEventTime?
    let end: MicrosoftEventTime?
    let isAllDay: Bool?
    let isCancelled: Bool?
    let showAs: String?
    let sensitivity: String?
    let subject: String?
    let lastModifiedDateTime: String?
    let removed: MicrosoftRemoved?

    enum CodingKeys: String, CodingKey {
        case id
        case seriesMasterID = "seriesMasterId"
        case originalStart
        case start
        case end
        case isAllDay
        case isCancelled
        case showAs
        case sensitivity
        case subject
        case lastModifiedDateTime
        case removed = "@removed"
    }

    func providerEvent(connectionID: String, calendarID: String) -> ProviderEvent {
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
            updatedAt: lastModifiedDateTime.flatMap { MicrosoftDate.date(from: $0) }
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
