import ArgumentParser
import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

struct CalendarReadSource: Sendable {
    let connection: StoredConnection
    let calendar: StoredCalendarBinding
}

struct CalendarRefreshSummary: Sendable {
    let ingestion: EventIngestionSummary
    let selectedSourceCount: Int
    let refreshedSourceCount: Int
    let failedSourceCount: Int
    let warnings: [String]
}

struct CalendarCommandRead {
    let repository: LocalStateRepository
    let sources: [CalendarReadSource]
    let refresh: CalendarRefreshSummary
    let readState: CalopodStateRead?
    let writerLock: ProcessLock?
}

func calendarCommandRead(
    environment: CalopodRuntimeEnvironment,
    cached: Bool,
    connectionID: String?,
    calendarID: String?,
    range: ResolvedDateRange,
    readSource: ((CalendarReadSource, Date, Date) async throws -> ProviderEventPage)? = nil
) async throws -> CalendarCommandRead {
    let readState: CalopodStateRead?
    let writerLock: ProcessLock?
    let repository: LocalStateRepository
    if cached {
        let state = try environment.readOnlyState()
        readState = state
        writerLock = nil
        repository = state.repository
    } else {
        try environment.stateLocation.prepareDirectory()
        writerLock = try ProcessLock.acquire(at: environment.stateLocation.lockURL)
        readState = nil
        repository = try environment.repository()
    }
    let sources = try selectedCalendarSources(connectionID: connectionID, calendarID: calendarID, repository: repository)
    let refresh: CalendarRefreshSummary
    if cached {
        refresh = CalendarRefreshSummary(ingestion: EventIngestionSummary(), selectedSourceCount: sources.count,
            refreshedSourceCount: 0, failedSourceCount: 0,
            warnings: ["Retained local data only; freshness and coverage of the requested range are not guaranteed. Run inbox refresh or omit --cached after sync finishes."])
    } else {
        refresh = await refreshCalendarSources(sources, from: range.window.start, through: range.window.end,
            repository: repository, readSource: readSource)
    }
    return CalendarCommandRead(repository: repository, sources: sources, refresh: refresh, readState: readState, writerLock: writerLock)
}

func selectedCalendarSources(
    connectionID: String?,
    calendarID: String?,
    repository: LocalStateRepository
) throws -> [CalendarReadSource] {
    let supportedConnections = try repository.connections().filter {
        $0.isEnabled && ["eventkit", "google", "microsoft"].contains($0.provider)
    }
    let connections: [StoredConnection]
    if let connectionID {
        guard let connection = supportedConnections.first(where: { $0.id == connectionID }) else {
            throw ValidationError("Connection '\(connectionID)' was not found or is not enabled.")
        }
        connections = [connection]
    } else {
        connections = supportedConnections
    }

    var sources: [CalendarReadSource] = []
    for connection in connections {
        let bindings = try repository.calendarBindings(connectionID: connection.id)
        sources.append(contentsOf: bindings.filter(\.isSelected).map {
            CalendarReadSource(connection: connection, calendar: $0)
        })
    }

    if let calendarID {
        guard let source = sources.first(where: { $0.calendar.id == calendarID }) else {
            throw ValidationError(
                "Calendar '\(calendarID)' was not found, is not selected, or does not belong to that Connection."
            )
        }
        return [source]
    }

    guard !sources.isEmpty else {
        throw ValidationError("Select at least one calendar before reading events or Availability.")
    }
    return sources
}

func refreshCalendarSources(
    _ sources: [CalendarReadSource],
    from start: Date,
    through end: Date,
    repository: LocalStateRepository,
    readSource: ((CalendarReadSource, Date, Date) async throws -> ProviderEventPage)? = nil
) async -> CalendarRefreshSummary {
    let cache = EventCache(repository: repository)
    var refreshedCount = 0
    var failedCount = 0
    var ingestion = EventIngestionSummary()
    var warnings: [String] = []

    // Grouped by connection so an EventKit refresh launches the host process
    // once for every selected calendar on that connection, not once per
    // calendar.
    var groups: [(connection: StoredConnection, sources: [CalendarReadSource])] = []
    for source in sources {
        if let index = groups.firstIndex(where: { $0.connection.id == source.connection.id }) {
            groups[index].sources.append(source)
        } else {
            groups.append((source.connection, [source]))
        }
    }

    for group in groups {
        var failureCode: String?
        if group.connection.provider == "eventkit", readSource == nil {
            do {
                let response = try EventKitHostRunner().perform(
                    EventKitHostRequest(
                        operation: .events,
                        calendarIDs: group.sources.map(\.calendar.providerCalendarID),
                        start: start,
                        end: end
                    )
                )
                guard response.status == .fullAccess, response.errorCode == nil else {
                    throw ProviderFailure.permissionDenied
                }
                for source in group.sources {
                    let page = ProviderEventPage(
                        events: response.events.filter {
                            $0.calendarID == source.calendar.providerCalendarID
                        },
                        nextSyncToken: nil,
                        refreshMode: .full
                    )
                    let result = try cache.apply(
                        page,
                        connection: source.connection,
                        calendar: source.calendar,
                        from: start,
                        through: end
                    )
                    ingestion.add(result.ingestion)
                    refreshedCount += 1
                }
            } catch {
                failedCount += group.sources.count
                failureCode = refreshFailureCode(error)
            }
        } else {
            for source in group.sources {
                do {
                    let page: ProviderEventPage
                    if let readSource { page = try await readSource(source, start, end) }
                    else {
                        page = try await readEvents(connection: source.connection, binding: source.calendar, start: start, end: end)
                    }
                    let result = try cache.apply(
                        page,
                        connection: source.connection,
                        calendar: source.calendar,
                        from: start,
                        through: end
                    )
                    ingestion.add(result.ingestion)
                    refreshedCount += 1
                } catch {
                    failedCount += 1
                    failureCode = failureCode ?? refreshFailureCode(error)
                }
            }
        }

        if let failureCode {
            try? repository.markConnectionStale(
                connectionID: group.connection.id,
                errorCode: failureCode
            )
            warnings.append(
                "\(providerDisplayName(group.connection.provider)) could not refresh every selected calendar; cached data may be stale."
            )
        }
    }

    warnings += ingestion.warnings
    return CalendarRefreshSummary(
        ingestion: ingestion,
        selectedSourceCount: sources.count,
        refreshedSourceCount: refreshedCount,
        failedSourceCount: failedCount,
        warnings: warnings
    )
}

private func refreshFailureCode(_ error: Error) -> String {
    guard let provider = error as? ProviderFailure else {
        if error is SecretStoreError { return "credential-access" }
        if error is CommandEnvironmentError { return "configuration" }
        return "local-state"
    }
    return switch provider {
    case .accountPolicyRequired: "account-policy"
    case .authorizationRequired: "authorization"
    case .configurationMissing: "configuration"
    case .consentDenied: "consent"
    case .cursorExpired: "cursor"
    case .httpStatus: "provider-http"
    case .invalidResponse: "provider-response"
    case .permissionDenied: "permission"
    case .refreshRejected: "authorization"
    case .temporaryFailure: "temporary"
    }
}

private func providerDisplayName(_ provider: String) -> String {
    switch provider {
    case "eventkit": "Calendars on this Mac"
    case "google": "Google Calendar"
    case "microsoft": "Microsoft Calendar"
    default: "Calendar provider"
    }
}
