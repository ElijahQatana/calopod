import ArgumentParser
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InboxContextOptions: ParsableArguments {
    @Option(name: .long) public var contextBeforeMinutes: Int?
    @Option(name: .long) public var contextAfterMinutes: Int?
    public init() {}
    func resolve(_ settings: InboxContextSettings) throws -> InboxContextSettings {
        do { return try settings.overriding(beforeMinutes: contextBeforeMinutes, afterMinutes: contextAfterMinutes) }
        catch { throw ValidationError("Context margins must be 0...10080 minutes and cannot both be zero.") }
    }
}

public struct InboxConfigCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "config", abstract: "Read or save review context margins.")
    @OptionGroup public var context: InboxContextOptions
    @OptionGroup public var output: OutputOptions
    public init() {}
    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let state = try CommandEnvironment.repository()
            let settings = try context.resolve(state.inboxContextSettings())
            try state.saveInboxContextSettings(settings)
            try OutputRenderer.write(command: "inbox.config", payload: CommandPayload(status: "ok",
                message: "Context: \(settings.beforeMinutes) minutes before and \(settings.afterMinutes) minutes after event start."), format: output.format)
        } catch { try failCommand(error) }
    }
}

public struct InboxReviewCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "review", abstract: "Review one event at a time; explicit RSVP choices may notify organizers.")
    @OptionGroup public var options: InboxOptions
    @OptionGroup public var context: InboxContextOptions
    @Flag(name: .long) public var resume = false
    @Flag(name: .long, help: "Suppress celebration art.") public var noDecoration = false
    public init() {}
    public func validate() throws {
        _ = try context.resolve(InboxContextSettings())
        _ = try resolveRange(options.range, default: .none)
        if resume && (options.connection != nil || options.calendar != nil || options.excludeMaybe || options.conflicts ||
            options.range.day != nil || options.range.from != nil || options.range.through != nil ||
            context.contextBeforeMinutes != nil || context.contextAfterMinutes != nil) {
            throw ValidationError("Resume uses the saved queue and context. Start a new session to change filters or margins.")
        }
    }
    public func run() async throws {
        do {
            guard options.output.format == .human, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                throw ValidationError("Review requires an interactive terminal and human output. Use inbox --format json for noninteractive reads.")
            }
            let state = try CommandEnvironment.repository()
            let range = try resolveRange(options.range, default: .none)
            let snapshot = try state.inboxContextSnapshot()
            let selected = try InboxCLI.snapshot(state, options: options)
            let settings = try context.resolve(state.inboxContextSettings())
            let controller = InboxReviewSessionController(state: state, lockURL: try CommandEnvironment.runtimeEnvironment().stateLocation.lockURL)
            let window = try InboxAttentionQuery.evaluate(snapshot, freshnessCutoff: Date().addingTimeInterval(-3600)).analysisWindow ??
                SyncWindow(start: Date(), end: Date().addingTimeInterval(1))
            let refresh: InboxReviewSessionController.Refresh = {
                let current = try state.inboxContextSnapshot()
                if current.sources.contains(where: { ["eventkit", "google", "microsoft"].contains($0.provider) }) {
                    let sources = try selectedCalendarSources(connectionID: nil, calendarID: nil, repository: state)
                    for source in sources {
                        guard let coverage = current.sources.first(where: { $0.bindingID == source.calendar.id })?.coverage else { continue }
                        _ = await refreshCalendarSources([source], from: coverage.startsAt, through: coverage.endsAt, repository: state)
                    }
                }
                return try state.inboxContextSnapshot()
            }
            let provider: InboxReviewSessionController.Provider = { target in
                switch target.provider {
                case "google": return try CommandEnvironment.googleService()
                case "microsoft": return try CommandEnvironment.microsoftService()
                default: throw RSVPActionError.unavailable(.unsupported)
                }
            }
            let input = ReviewTerminalInput()
            defer { input.close() }
            let session: InboxReviewSession
            if resume {
                session = try await controller.resume(freshnessCutoff: Date().addingTimeInterval(-3600), refresh: refresh, provider: provider)
            } else {
                session = try controller.start(filter: InboxAttentionFilter(window: range?.window,
                    excludeMaybe: options.excludeMaybe, conflictsOnly: options.conflicts,
                    bindingIDs: Set(selected.sources.map(\.bindingID))), settings: settings,
                    metricsWindow: window, freshnessCutoff: Date().addingTimeInterval(-3600),
                    displayTimeZoneIdentifier: options.range.timezone ?? TimeZone.current.identifier)
            }
            let environment = ProcessInfo.processInfo.environment
            let terminal = InboxReviewTerminal(controller: controller, refresh: refresh, provider: provider,
                read: { input.line() }, write: { print($0) }, width: input.width,
                decoration: !noDecoration && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb",
                timezone: TimeZone(identifier: options.range.timezone ?? session.displayTimeZoneIdentifier ?? "") ?? .current)
            _ = try await terminal.run(session)
        } catch InboxReviewSessionError.noSession { try failCommand(ValidationError("No unfinished review session. Start with calopod inbox review.")) }
        catch { try failCommand(error) }
    }
}

private final class ReviewTerminalInput: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var source: DispatchSourceSignal?
    private var oldHandler: sig_t?
    var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }
    init() {
        oldHandler = signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.interrupted = true }
        }
        source.resume()
        self.source = source
    }
    func close() { source?.cancel(); _ = signal(SIGINT, oldHandler) }
    func line() -> String? {
        var bytes: [UInt8] = []
        while !lock.withLock({ interrupted }) && !Task.isCancelled {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            if bytes.count < 256 { bytes.append(byte) }
        }
        return nil
    }
}
