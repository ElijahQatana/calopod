import ArgumentParser
import CalopodStore
import Foundation

/// The iPhone feed is a read-only copy of the Inbox and busy time that the Mac app uploads to the
/// private iCloud of whoever signed in. These commands only choose whether it is on; the app does the
/// uploading.
public struct IPhoneCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "iphone",
        abstract: "Turn the iPhone feed on or off and see how it is doing.",
        subcommands: [IPhoneOnCommand.self, IPhoneOffCommand.self, IPhoneStatusCommand.self],
        defaultSubcommand: IPhoneStatusCommand.self
    )

    public init() {}
}

public struct IPhoneOnCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "on", abstract: "Start publishing the iPhone feed.")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            guard IPhoneFeedAvailability.current.isAvailable else {
                throw ValidationError(IPhoneFeedAvailability.current.unavailableMessage)
            }
            try IPhoneFeedService().setEnabled(true)
            try write("iphone.on", "The iPhone feed is on. The Calopod app uploads it after the next sync.", output)
        } catch {
            try failCommand(error, format: output.format)
        }
    }
}

public struct IPhoneOffCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Stop publishing and delete the uploaded copy.")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            try IPhoneFeedService().setEnabled(false)
            let pending = (try? IPhoneFeedService().state().removePending) ?? false
            try write(
                "iphone.off",
                pending
                    ? "The iPhone feed is off. The Calopod app deletes the uploaded copy the next time it runs."
                    : "The iPhone feed is off.",
                output)
        } catch {
            try failCommand(error, format: output.format)
        }
    }
}

public struct IPhoneStatusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the iPhone feed is on.")

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        do {
            let feed = try IPhoneFeedService().state()
            try write("iphone.status", IPhoneFeedAvailability.current.describe(feed), output, enabled: feed.isEnabled)
        } catch {
            try failCommand(error, format: output.format)
        }
    }
}

private func write(_ command: String, _ message: String, _ output: OutputOptions, enabled: Bool? = nil) throws {
    try OutputRenderer.write(
        command: command, payload: CommandPayload(status: "ok", message: message, enabled: enabled),
        format: output.format, showIDs: output.ids)
}

/// Whether this copy of Calopod can publish at all. Only the signed app can, so a source install
/// reports the feed as not available.
public enum IPhoneFeedAvailability: Equatable, Sendable {
    case available
    case noApp
    /// An app is here but carries no provisioning profile, such as a local build, so iCloud refuses it.
    case notSigned

    static let provisioningProfile = "Contents/embedded.provisionprofile"

    public static var current: IPhoneFeedAvailability {
        #if os(macOS)
        check(app: AppServiceLocator.installedApp(), exists: { FileManager.default.fileExists(atPath: $0) })
        #else
        .noApp
        #endif
    }

    public static func check(app: URL?, exists: (String) -> Bool) -> IPhoneFeedAvailability {
        guard let app else { return .noApp }
        return exists(app.appendingPathComponent(provisioningProfile).path) ? .available : .notSigned
    }

    public var isAvailable: Bool { self == .available }

    public var unavailableMessage: String {
        switch self {
        case .available: ""
        case .noApp: "The iPhone feed needs the Calopod app. It is not available with the command line alone."
        case .notSigned: "This copy of the Calopod app is not signed for iCloud, so it cannot publish the iPhone feed."
        }
    }

    public func describe(_ feed: StoredIPhoneFeed) -> String {
        switch self {
        case .noApp: return "iPhone feed: not available (no app)"
        case .notSigned: return "iPhone feed: not available (this app is not signed for iCloud)"
        case .available: break
        }
        if feed.removePending { return "iPhone feed: off. The uploaded copy will be deleted the next time the app runs." }
        guard feed.isEnabled else { return "iPhone feed: off" }
        var text = "iPhone feed: on."
        if let failure = feed.failure { text += " The last upload failed: \(failure)" }
        else if let published = feed.publishedAt { text += " Last uploaded \(published.formatted(date: .abbreviated, time: .shortened))." }
        else { text += " Waiting for the app to upload it." }
        return text
    }
}

/// The `calopod doctor` line for the feed. It never reads the state when there is no app to publish.
func iPhoneFeedDoctorItem(
    availability: IPhoneFeedAvailability = .current,
    feed: () -> StoredIPhoneFeed? = { try? IPhoneFeedService().state() }
) -> (item: CommandItem, warning: String?) {
    switch availability {
    case .noApp: return (CommandItem(id: "iphone-feed", kind: "skipped", label: availability.describe(StoredIPhoneFeed()), reason: "no-app"), nil)
    case .notSigned: return (CommandItem(id: "iphone-feed", kind: "skipped", label: availability.describe(StoredIPhoneFeed()), reason: "not-signed"), nil)
    case .available:
        guard let feed = feed() else { return (CommandItem(id: "iphone-feed", kind: "skipped", label: nil, reason: "unreadable"), nil) }
        let label = availability.describe(feed)
        if feed.isEnabled, feed.failure != nil {
            return (CommandItem(id: "iphone-feed", kind: "attention", label: label, reason: "upload-failed"),
                    "The iPhone feed could not be uploaded. Open the Calopod app and check Settings.")
        }
        return (CommandItem(id: "iphone-feed", kind: "ok", label: label, reason: feed.isEnabled ? "on" : "off"), nil)
    }
}
