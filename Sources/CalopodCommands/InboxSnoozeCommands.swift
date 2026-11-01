import ArgumentParser
import CalopodStore
import CalopodSync
import Foundation

public struct InboxSnoozeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "snooze",
        abstract: "Hide one item until later; never send RSVP.")
    @Argument public var itemID: String
    @Option(name: .long, help: "later, tomorrow, or a date as YYYY-MM-DD.") public var until: String
    @OptionGroup public var output: OutputOptions
    public init() {}
    public func run() async throws {
        do {
            let choice = try InboxCLI.snoozeChoice(until)
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            try OutputRenderer.write(command: "inbox.snooze", payload: try InboxCLI.snooze(itemID, until: choice, repository: repository),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error) }
    }
}

public struct InboxUnsnoozeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "unsnooze", abstract: "Bring a snoozed item back now.")
    @Argument public var itemID: String
    @OptionGroup public var output: OutputOptions
    public init() {}
    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            try OutputRenderer.write(command: "inbox.unsnooze", payload: try InboxCLI.unsnooze(itemID, repository: repository),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error) }
    }
}

extension InboxCLI {
    static func snoozeChoice(_ text: String) throws -> InboxSnoozeChoice {
        switch text {
        case "later": return .laterToday
        case "tomorrow": return .tomorrow
        default:
            guard let day = try DateRangeResolver(day: text).resolve(default: .none) else { throw ValidationError("Use later, tomorrow or YYYY-MM-DD.") }
            return .day(day.window.start)
        }
    }

    /// The item must still be the revision that was listed, so a newer edit is never snoozed unseen.
    static func snooze(_ identifier: String, until choice: InboxSnoozeChoice, repository: LocalStateRepository,
                       now: Date = Date()) throws -> CommandPayload {
        let (key, revision) = try parse(identifier)
        guard let until = choice.until(from: now) else { throw ValidationError("That time has already passed.") }
        let snapshot = try repository.inboxContextSnapshot()
        guard let item = snapshot.events.first(where: { $0.event.sourceKeyHash == key }) else {
            throw ValidationError("Item is unavailable in selected sources.")
        }
        guard (item.observation?.revision ?? 1) == revision else { throw ValidationError("Item changed since it was listed. List it again.") }
        guard let snooze = InboxAttentionQuery.snooze(key, until: until, in: snapshot, asOf: now, freshnessCutoff: now.addingTimeInterval(-3600)) else {
            throw ValidationError("Item is not in the inbox.")
        }
        try repository.snoozeInboxItem(snooze, now: now)
        return CommandPayload(status: "ok", message: "Snoozed until \(date(until)!). No reply was sent; RSVP and conflicts are unchanged.", count: 1)
    }

    static func unsnooze(_ identifier: String, repository: LocalStateRepository) throws -> CommandPayload {
        let key = (try? parse(identifier).0) ?? identifier
        guard try repository.inboxSnoozes()[key] != nil else { throw ValidationError("Item is not snoozed.") }
        try repository.unsnoozeInboxItem(sourceKeyHash: key)
        return CommandPayload(status: "ok", message: "Item is back in the inbox.", count: 1)
    }
}
