import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        updatedSince: Date? = nil
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
                    fallbackTimeZone: fallbackTimeZone
                )
            })
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil

        return ProviderEventPage(events: events, nextSyncToken: nextSyncToken)
    }

    private func send(url: URL, accessToken: String) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
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
    let recurringEventID: String?
    let originalStartTime: GoogleEventTime?
    let start: GoogleEventTime?
    let end: GoogleEventTime?
    let status: String?
    let transparency: String?
    let visibility: String?
    let summary: String?
    let updated: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recurringEventID = "recurringEventId"
        case originalStartTime
        case start
        case end
        case status
        case transparency
        case visibility
        case summary
        case updated
    }

    func providerEvent(
        connectionID: String,
        calendarID: String,
        fallbackTimeZone: TimeZone
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
            updatedAt: updated.flatMap(RFC3339.date(from:))
        )
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
