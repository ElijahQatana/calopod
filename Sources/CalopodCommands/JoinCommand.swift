import ArgumentParser
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

/// Opens a meeting URL with `/usr/bin/open`. It cannot ask which app handles a scheme, so it tries and reads the exit status.
struct OpenCommandOpener: MeetingURLOpening {
    func hasHandler(for url: URL) -> Bool { true }

    func open(_ url: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Which event `calopod join` opens.
enum JoinChoice: Equatable {
    case event(StoredNormalizedInstance, MeetingLink)
    case unknownEvent
    case noLink
    case nothingSoon
}

enum JoinSelector {
    static let lookahead: TimeInterval = 12 * 3600

    static func link(for event: StoredNormalizedInstance) -> MeetingLink? {
        MeetingLink.find(url: event.url, location: event.location, notes: event.notes)
    }

    /// With an id, that event. Without one, the event the menu bar card treats as next (`NextUpSelection`)
    /// among those running or starting within 12 hours. When that event has no link, the card's second
    /// line is tried, then says it has no link.
    static func choose(id: String?, from events: [StoredNormalizedInstance], now: Date) -> JoinChoice {
        if let id {
            guard let event = events.first(where: { $0.sourceKeyHash == id }) else { return .unknownEvent }
            return link(for: event).map { .event(event, $0) } ?? .noLink
        }
        let candidates = events.filter {
            !$0.isAllDay && !$0.isCancelled && $0.currentUserResponse.state != .declined
                && $0.startsAt <= now.addingTimeInterval(lookahead)
        }
        let byID = Dictionary(candidates.map { ($0.sourceKeyHash, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = NextUpSelection.select(
            candidates.map { NextUpEntry(id: $0.sourceKeyHash, startsAt: $0.startsAt, endsAt: $0.endsAt) }, now: now)
        for line in [chosen.primary, chosen.secondary].compactMap({ $0 }) {
            if let event = byID[line.event.id], let link = link(for: event) { return .event(event, link) }
        }
        return chosen.primary == nil ? .nothingSoon : .noLink
    }

    /// Original events only. A copy Calopod made never offers Join.
    static func originals(in repository: LocalStateRepository, calendarNames: CalendarNames) throws -> [StoredNormalizedInstance] {
        try repository.inboxContextSnapshot().events
            .map(\.event)
            .filter { !calendarNames.isIgnored($0.calendarBindingID) }
    }
}

/// Opens the meeting link of an event from the local copy.
public struct JoinCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Open the meeting link of an event.",
        discussion: "Takes an id from `calopod events --ids`. Without one, joins the event the menu bar card shows as next: the one on now during its first 10 minutes, then the next one to start. Opens the meeting app when it is installed, otherwise the web link."
    )

    @Argument(help: "An event id from `calopod events --ids`.")
    public var event: String?

    public init() {}

    public func run() async throws {
        let message: String
        do {
            let state = try CommandEnvironment.runtimeEnvironment().readOnlyState()
            let events = try JoinSelector.originals(in: state.repository, calendarNames: CalendarNames(state.repository))
            message = await Self.join(id: event, events: events, now: Date(), joiner: MeetingJoiner(opener: OpenCommandOpener()))
        } catch {
            try failCommand(error)
        }
        print(message)
    }

    static func join(id: String?, events: [StoredNormalizedInstance], now: Date, joiner: any MeetingJoining) async -> String {
        switch JoinSelector.choose(id: id, from: events, now: now) {
        case .unknownEvent: return "No event with that id was found. Ids are listed by `calopod events --ids`."
        case .noLink: return "That event has no meeting link."
        case .nothingSoon: return "No event is on now or starts within 12 hours."
        case let .event(event, link):
            let title = event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event"
            switch await joiner.join(link) {
            case .openedApp: return "Opened \(link.provider.displayName) for \(HumanOutputRenderer.clean(title))."
            case .openedWeb: return "Opened the \(link.provider.displayName) link in the browser for \(HumanOutputRenderer.clean(title))."
            case .failed: return MeetingJoinText.failed
            }
        }
    }
}
