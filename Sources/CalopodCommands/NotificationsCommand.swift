import ArgumentParser
import CalopodStore
import Foundation

/// The reminder and digest settings as `calopod notifications --format json` prints them.
public struct NotificationSettingsOutput: Codable, Equatable, Sendable {
    public struct Reminder: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let minutes: Int
    }

    public struct Digest: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let time: String
    }

    public let enabled: Bool
    public let first: Reminder
    public let final: Reminder
    public let hideTitles: Bool
    public let digest: Digest
    /// The command line cannot read what macOS allowed, so this is always "managed-by-app".
    public let permission: String

    public init(_ settings: NotificationSettings, digest: InboxDigestSettings = .standard, workingHours: WorkingHours = .standard) {
        enabled = settings.enabled
        first = Reminder(enabled: settings.firstEnabled, minutes: settings.firstMinutes)
        final = Reminder(enabled: settings.finalEnabled, minutes: settings.finalMinutes)
        hideTitles = settings.hideTitles
        self.digest = Digest(enabled: digest.enabled, time: HoursText.clock(digest.minute(workingHours: workingHours)))
        permission = "managed-by-app"
    }
}

enum NotificationsText {
    static func minutes(_ count: Int) -> String { count == 1 ? "1 minute" : "\(count) minutes" }

    static func lines(
        _ settings: NotificationSettings, digest: InboxDigestSettings = .standard, workingHours: WorkingHours = .standard
    ) -> [String] {
        func reminder(_ name: String, _ on: Bool, _ count: Int) -> String {
            "\(name): \(on ? "\(minutes(count)) before the start" : "off")"
        }
        return [
            "Reminders: \(settings.enabled ? "on" : "off")",
            reminder("First reminder", settings.firstEnabled, settings.firstMinutes),
            reminder("Final reminder", settings.finalEnabled, settings.finalMinutes),
            "Event titles: \(settings.hideTitles ? "hidden" : "shown")",
            digest.enabled ? "Inbox digest: on at \(HoursText.clock(digest.minute(workingHours: workingHours)))" : "Inbox digest: off",
            "Notification permission: managed by the app. The command line cannot read it; see Settings, Permissions in Calopod.",
            "Reminders and the digest are shown by the Calopod app. Changes made here are picked up the next time it refreshes.",
        ]
    }
}

public struct NotificationsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notifications",
        abstract: "Show or change meeting reminder and Inbox digest settings.",
        discussion: "Reminders and the digest are shown by the Calopod app, so they need the app installed. Whether macOS allows them is managed by the app and cannot be read here.",
        subcommands: [NotificationsSetCommand.self])

    @OptionGroup public var output: OutputOptions
    public init() {}

    public func run() async throws {
        do {
            try writeNotifications(try CommandEnvironment.repository(), message: nil, format: output.format)
        } catch { try failCommand(error, format: output.format) }
    }
}

public struct NotificationsSetCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change meeting reminder and Inbox digest settings.",
        discussion: "Times are minutes before the start, from 1 to 120. When both reminders are on, the final one must be closer to the start than the first. Use --no-first or --no-final to turn one off. The digest is one notification a day with counts of what is waiting in the Inbox, at the time you give or at the start of your working day.")

    @Option(name: .long, help: "Minutes before the start for the first reminder (1 to 120).")
    public var first: Int?
    @Option(name: .customLong("final"), help: "Minutes before the start for the final reminder (1 to 120).")
    public var finalMinutes: Int?
    @Flag(name: .customLong("no-first"), help: "Turn the first reminder off.") public var noFirst = false
    @Flag(name: .customLong("no-final"), help: "Turn the final reminder off.") public var noFinal = false
    @Flag(name: .long, help: "Hide event titles in notifications.") public var hideTitles = false
    @Flag(name: .long, help: "Show event titles in notifications.") public var showTitles = false
    @Flag(name: .long, help: "Turn reminders on.") public var on = false
    @Flag(name: .long, help: "Turn all reminders off.") public var off = false
    @Flag(name: .long, help: "Turn the daily Inbox digest on.") public var digest = false
    @Flag(name: .customLong("no-digest"), help: "Turn the daily Inbox digest off.") public var noDigest = false
    @Option(name: .long, help: "When the digest is sent, as HH:MM. Turns it on.") public var digestAt: String?
    @OptionGroup public var output: OutputOptions
    public init() {}

    public func validate() throws {
        if digest && noDigest { throw ValidationError("Choose either --digest or --no-digest.") }
        if noDigest && digestAt != nil { throw ValidationError("--no-digest and --digest-at cannot be used together.") }
        if hideTitles && showTitles { throw ValidationError("Choose either --hide-titles or --show-titles.") }
        if on && off { throw ValidationError("Choose either --on or --off.") }
        if noFirst && first != nil { throw ValidationError("--no-first and --first cannot be used together.") }
        if noFinal && finalMinutes != nil { throw ValidationError("--no-final and --final cannot be used together.") }
        if first == nil && finalMinutes == nil && !noFirst && !noFinal && !hideTitles && !showTitles && !on && !off
            && !digest && !noDigest && digestAt == nil {
            throw ValidationError("Nothing to change. Give --first, --final, --no-first, --no-final, --hide-titles, --show-titles, --on, --off, --digest, --no-digest or --digest-at.")
        }
    }

    /// The settings after applying these options, checked the same way as in the app.
    func resolve(_ current: NotificationSettings) throws -> NotificationSettings {
        try current.changing(
            enabled: on ? true : off ? false : nil,
            firstEnabled: noFirst ? false : first != nil ? true : nil, firstMinutes: first,
            finalEnabled: noFinal ? false : finalMinutes != nil ? true : nil, finalMinutes: finalMinutes,
            hideTitles: hideTitles ? true : showTitles ? false : nil)
    }

    func resolveDigest(_ current: InboxDigestSettings) throws -> InboxDigestSettings {
        try InboxDigestSettings(
            enabled: noDigest ? false : digest || digestAt != nil ? true : current.enabled,
            minute: try digestAt.map(HoursText.minute) ?? current.minute)
    }

    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let state = try CommandEnvironment.repository()
            let settings = try resolve(state.notificationSettings())
            let digestSettings = try resolveDigest(state.inboxDigestSettings())
            try state.saveNotificationSettings(settings)
            try state.saveInboxDigestSettings(digestSettings)
            try writeNotifications(state, message: "Saved. The Calopod app picks the change up the next time it refreshes.", format: output.format)
        } catch { try failCommand(error, format: output.format) }
    }
}

private func writeNotifications(_ state: LocalStateRepository, message: String?, format: OutputFormat) throws {
    let settings = try state.notificationSettings(), digest = try state.inboxDigestSettings()
    let hours = try state.workingHours()
    let summary = message ?? "Meeting reminders are \(settings.enabled ? "on" : "off")."
    try OutputRenderer.write(
        command: "notifications",
        payload: CommandPayload(
            status: "ok", message: summary, enabled: settings.enabled,
            notifications: NotificationSettingsOutput(settings, digest: digest, workingHours: hours)),
        format: format, human: HumanOutputContext(footer: NotificationsText.lines(settings, digest: digest, workingHours: hours)))
}
