import CalopodStore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Local presentation context is deliberately separate from the JSON envelope.
public struct HumanOutputContext: Sendable {
    public var calendarLabels: [String: String]
    public var connectionLabels: [String: String]
    public var connectionEnabled: [String: Bool]
    public var applied: Int?
    public var reconciled: Int?
    public var noOps: Int?

    public init(
        calendarLabels: [String: String] = [:],
        connectionLabels: [String: String] = [:],
        connectionEnabled: [String: Bool] = [:],
        applied: Int? = nil, reconciled: Int? = nil, noOps: Int? = nil
    ) {
        self.calendarLabels = calendarLabels
        self.connectionLabels = connectionLabels
        self.connectionEnabled = connectionEnabled
        self.applied = applied
        self.reconciled = reconciled
        self.noOps = noOps
    }
}

extension OutputOptions {
    func localContext(repository: LocalStateRepository) -> HumanOutputContext {
        guard format == .human else { return HumanOutputContext() }
        // Missing cached labels must not turn a successful configuration change into a failure.
        let connections = (try? repository.connections()) ?? []
        let calendars = connections.flatMap { (try? repository.calendarBindings(connectionID: $0.id)) ?? [] }
        return HumanOutputContext(
            calendarLabels: Dictionary(calendars.compactMap { calendar in
                calendar.displayLabel.map { (calendar.id, $0) }
            }, uniquingKeysWith: { first, _ in first }),
            connectionLabels: Dictionary(connections.compactMap { connection in
                connection.displayLabel.map { (connection.id, $0) }
            }, uniquingKeysWith: { first, _ in first }),
            connectionEnabled: Dictionary(connections.map { ($0.id, $0.isEnabled) }, uniquingKeysWith: { first, _ in first })
        )
    }
}

enum HumanOutputRenderer {
    static var terminalWidth: Int {
        #if canImport(Darwin)
        var size = winsize()
        if isatty(STDOUT_FILENO) == 1, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        #endif
        return 80
    }

    static func render(
        command: String, payload: CommandPayload, warnings: [String],
        showIDs: Bool, context: HumanOutputContext, width: Int
    ) -> String {
        let shared = command == "doctor" || command.hasPrefix("support.") || command.hasPrefix("agent.")
        let localIDs = showIDs && !shared && command != "sync"
        var lines = [clean(payload.message), "Status: \(clean(payload.status))"]
        if let count = payload.count, command != "sync" { lines.append("Count: \(count)") }
        if let mode = payload.mode {
            lines.append("Mode: \(mode == "dry-run" ? "Preview (no calendar writes)" : clean(mode))")
        }
        if let range = payload.range {
            lines += ["From: \(range.start)", "Through: \(range.endExclusive) (exclusive)", "Timezone: \(range.timezone)"]
        }
        if command == "sync" {
            let items = payload.items ?? []
            lines.append("Planned operations: \(items.count)")
            for (kind, label) in [("create", "Create"), ("update", "Update"), ("remove", "Remove"), ("repair", "Repair"), ("no-op", "Already matching")] {
                lines.append("\(label): \(items.filter { $0.kind == kind }.count)")
            }
            if payload.mode == "dry-run" {
                lines.append("Applied changes: 0 (preview)")
            } else {
                if let count = context.applied { lines.append("Applied changes: \(count)") }
                if let count = context.reconciled { lines.append("Local reconciliations: \(count)") }
                if let count = context.noOps { lines.append("No-ops: \(count)") }
            }
            let reasons = Dictionary(grouping: items.compactMap(\.reason), by: { $0 })
            for reason in reasons.keys.sorted() {
                lines.append("\(readable(reason)): \(reasons[reason]?.count ?? 0)")
            }
        } else {
            if !shared, let sources = payload.sources {
                lines.append("Sources: \(sources.count)")
                for (index, source) in sources.enumerated() {
                    lines.append("  \(index + 1). \(label(source.label, fallback: "Unnamed calendar")) (\(clean(source.provider)))")
                    if let coverage = source.inbox {
                        lines.append("  Coverage: \(coverage.startsAt ?? "unknown") to \(coverage.endsAt ?? "unknown")")
                        lines.append("  Freshness: \(coverage.status); observed \(coverage.observedAt ?? "never")")
                    }
                    if localIDs { lines += ["  Source ID: \(clean(source.id))", "  Connection ID: \(clean(source.connectionID))"] }
                }
            }
            if let items = payload.items {
                for (index, item) in items.enumerated() {
                    lines.append("")
                    if shared {
                        // Shared health reports use only fixed check names, statuses, and reasons.
                        if command == "doctor" || command == "support.export" {
                            lines.append("\(readable(item.id)): \(readable(item.kind))")
                            if let reason = item.reason { lines.append("  Reason: \(readable(reason))") }
                        }
                        continue
                    }
                    switch command {
                    case let name where name.hasPrefix("arm.") || name.hasPrefix("main."):
                        lines.append("\(index + 1). \(label(item.label, fallback: item.kind == "main-calendar" ? "Main calendar" : "Unnamed Arm"))")
                        if let enabled = item.enabled { lines.append("  State: \(enabled ? "enabled" : "disabled")") }
                        if let rule = item.rule { lines.append("  Rule: \(rule == "full-details" ? "Full details" : readable(rule))") }
                        if let sources = item.sourceIDs {
                            lines.append("  Sources: \(sources.count)")
                            for source in sources {
                                lines.append("    \(label(context.calendarLabels[source], fallback: "Unknown calendar"))")
                                if localIDs { lines.append("    Source ID: \(clean(source))") }
                            }
                        }
                        if let target = item.targetID {
                            lines.append("  Destination: \(label(context.calendarLabels[target], fallback: "Unknown calendar"))")
                            if localIDs { lines.append("  Destination ID: \(clean(target))") }
                        }
                    case "calendars":
                        lines.append("\(index + 1). \(label(item.label, fallback: "Unnamed calendar"))")
                        if let selected = item.selected { lines.append("  Selected: \(selected ? "yes" : "no")") }
                        if let readOnly = item.readOnly { lines.append("  Access: \(readOnly ? "read only" : "writable")") }
                        if let sourceLabel = item.sourceLabel { lines.append("  Account: \(clean(sourceLabel))") }
                        if let sourceType = item.sourceType { lines.append("  Provider: \(readable(sourceType))") }
                        if let parent = item.parentID {
                            lines.append("  Connection: \(label(context.connectionLabels[parent], fallback: "Unnamed Connection"))")
                            if localIDs { lines.append("  Connection ID: \(clean(parent))") }
                        }
                    case "events", "inbox", "inbox.activity", "inbox.inspect":
                        lines.append("\(index + 1). \(label(item.label, fallback: "Untitled event"))")
                        if let parent = item.parentID {
                            let source = payload.sources?.first { $0.id == parent }
                            lines.append("  Calendar: \(label(source?.label ?? context.calendarLabels[parent], fallback: "Unknown calendar"))")
                            if let connectionID = source?.connectionID {
                                lines.append("  Connection: \(label(context.connectionLabels[connectionID], fallback: "Unnamed Connection"))")
                            }
                            if localIDs { lines.append("  Calendar ID: \(clean(parent))") }
                        }
                        if let start = item.startsAt { lines.append("  From: \(clean(start))") }
                        if let end = item.endsAt { lines.append("  Through: \(clean(end))") }
                        if item.allDay == true { lines.append("  All day: yes") }
                        if item.cancelled == true { lines.append("  Cancelled: yes") }
                        if let availability = item.availability { lines.append("  Availability: \(readable(availability))") }
                    case "availability":
                        lines.append("\(index + 1). \(readable(item.availability ?? "unknown"))")
                        if let start = item.startsAt { lines.append("  From: \(clean(start))") }
                        if let end = item.endsAt { lines.append("  Through: \(clean(end))") }
                    default:
                        lines.append("\(index + 1). \(label(item.label, fallback: "Unnamed Connection"))")
                        lines.append("  Provider: \(readable(item.kind))")
                        if let enabled = context.connectionEnabled[item.id] {
                            lines.append("  State: \(enabled ? "enabled" : "disabled")")
                        }
                    }
                    if let inbox = item.inbox {
                        lines.append("  Response: \(readable(inbox.response.state.rawValue))")
                        lines.append("  Reviewed: \(inbox.reviewed ? "yes" : "no")")
                        if localIDs, let current = inbox.currentRevisionID { lines.append("  Current revision: \(clean(current))") }
                        if let responded = inbox.response.respondedAt { lines.append("  Response timestamp: \(InboxCLI.date(responded)!)") }
                        lines.append("  Response evidence: \(readable(inbox.response.evidence.rawValue))")
                        lines.append("  Current reasons: \(inbox.reasons.map { $0 == "needs-response" ? "Needs RSVP" : readable($0) }.joined(separator: ", "))")
                        if !inbox.activityTypes.isEmpty { lines.append("  Activity: \(inbox.activityTypes.map(readable).joined(separator: ", "))") }
                        if !inbox.changedFields.isEmpty { lines.append("  Changed: \(inbox.changedFields.joined(separator: ", "))") }
                        lines.append("  Timing: \(readable(inbox.timing))")
                        if let observed = inbox.observedAt { lines.append("  Observed: \(clean(observed))") }
                        if let acknowledged = inbox.acknowledgedAt { lines.append("  Reviewed: \(clean(acknowledged))") }
                        if let location = inbox.location { lines.append("  Location: \(clean(location))") }
                        if let notes = inbox.notes { lines.append("  Notes: \(clean(notes))") }
                        if let url = inbox.url { lines.append("  Link: \(clean(url))") }
                        if let organizer = inbox.organizer { lines.append("  Organizer: \(clean(organizer.name ?? organizer.emailAddress ?? "Unknown"))") }
                        for conflict in inbox.conflicts {
                            lines.append("  Conflict: \(label(conflict.label, fallback: "Untitled event")) / \(label(conflict.calendarLabel, fallback: "Unknown calendar")): \(clean(conflict.startsAt)) to \(clean(conflict.endsAt))")
                            if localIDs { lines.append("    Event ID: \(clean(conflict.eventID))") }
                        }
                        lines.append("  Limits: \(inbox.limits.map(readable).joined(separator: ", "))")
                    }
                    if localIDs { lines.append("  ID: \(clean(item.id))") }
                }
                if !items.isEmpty && !shared && !localIDs && command != "availability" {
                    lines.append("")
                    lines.append("Use --ids to show exact identifiers for commands.")
                }
            }
        }
        if let installed = payload.installed { lines.append("Installed: \(installed ? "yes" : "no")") }
        if let enabled = payload.enabled { lines.append("Enabled: \(enabled ? "yes" : "no")") }
        if let paused = payload.paused { lines.append("Paused: \(paused ? "yes" : "no")") }
        if let runState = payload.runState { lines.append("Run state: \(runState)") }
        if let stateReady = payload.stateReady { lines.append("State ready: \(stateReady ? "yes" : "no")") }
        if let interval = payload.intervalSeconds { lines.append("Interval: \(interval) seconds") }
        if let jitter = payload.jitterSeconds { lines.append("Jitter: \(jitter) seconds") }
        if let lookback = payload.lookbackDays { lines.append("Lookback: \(lookback) days") }
        if let horizon = payload.horizonDays { lines.append("Horizon: \(horizon) days") }
        if let age = payload.lastSuccessAgeSeconds {
            lines.append("Last success age: \(age) seconds")
        }
        if let failure = payload.failureCategory {
            lines.append("Failure category: \(failure)")
        }
        if let planned = payload.planned { lines.append("Planned: \(planned)") }
        if let applied = payload.applied { lines.append("Applied: \(applied)") }
        if let creates = payload.creates { lines.append("Creates: \(creates)") }
        if let updates = payload.updates { lines.append("Updates: \(updates)") }
        if let removals = payload.removals { lines.append("Removals: \(removals)") }
        if let repairs = payload.repairs { lines.append("Repairs: \(repairs)") }
        if let noOps = payload.noOps { lines.append("No-ops: \(noOps)") }
        if let ingestion = payload.ingestion {
            lines += [
                "Excluded marked copies: \(ingestion.excludedMarkedCopyCount)",
                "Excluded mapped copies: \(ingestion.excludedMappedCopyCount)",
                "Invalid identities: \(ingestion.invalidIdentityCount)",
                "Invalid timespans: \(ingestion.invalidTimespanCount)",
                "Outside requested window: \(ingestion.outOfRangeCount)",
            ]
        }
        if let review = payload.review {
            lines += [
                "Recurring occurrence creates: \(review.recurringOccurrenceCreateCount)",
                "Legacy recurring removal candidates: \(review.legacyRecurringRemovalCandidateCount)",
                "Other source-missing removals: \(review.otherSourceMissingRemovalCount)",
                "Stale mapping cleanup: \(review.staleMappingCleanupCount)",
                "Missing target recreation: \(review.targetRecreationCount)",
                "Other repairs: \(review.otherRepairCount)",
                "Removal candidates require review; counts do not prove source cancellation.",
            ]
        }
        if let warningCount = payload.warningCount {
            lines.append("Warning count: \(warningCount)")
        }
        if let count = payload.connectionCount { lines.append("Connections: \(count)") }
        if let count = payload.enabledConnectionCount {
            lines.append("Enabled Connections: \(count)")
        }
        if let count = payload.selectedCalendarCount {
            lines.append("Selected calendars: \(count)")
        }
        if let count = payload.armCount { lines.append("Arms: \(count)") }
        if let count = payload.enabledArmCount { lines.append("Enabled Arms: \(count)") }
        if let configured = payload.mainConfigured {
            lines.append("Main configured: \(configured ? "yes" : "no")")
        }
        if let count = payload.busyArmCount { lines.append("Busy Arms: \(count)") }
        if let valid = payload.backupValid { lines.append("Backup valid: \(valid ? "yes" : "no")") }
        if let count = payload.migrationCount { lines.append("Migrations: \(count)") }
        lines.append(contentsOf: warnings.map { "Warning: \(clean($0))" })
        return lines.flatMap { wrap($0, width: max(10, width)) }.joined(separator: "\n")
    }

    static func clean(_ value: String) -> String {
        value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
    }

    private static func label(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return clean(value)
    }

    private static func readable(_ value: String) -> String {
        clean(value).replacingOccurrences(of: "-", with: " ")
    }

    private static func columns(_ character: Character) -> Int {
        let wide = character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return scalar.properties.isEmojiPresentation ||
                (0x1100...0x115f).contains(value) || (0x2e80...0xa4cf).contains(value) ||
                (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value) ||
                (0xfe10...0xfe6f).contains(value) || (0xff01...0xff60).contains(value) ||
                (0x20000...0x3fffd).contains(value)
        }
        return wide ? 2 : 1
    }

    private static func wrap(_ line: String, width: Int) -> [String] {
        // Exact identifiers stay on one line so copying never changes their value.
        if ["ID: ", "Source ID: ", "Connection ID: ", "Destination ID: ", "Calendar ID: "].contains(where: { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) { return [line] }
        let indentation = String(line.prefix(while: { $0 == " " }))
        var remaining = String(line.dropFirst(indentation.count))
        var result: [String] = []
        let capacity = max(1, width - indentation.count)
        while remaining.reduce(0, { $0 + columns($1) }) > capacity {
            var end = remaining.startIndex
            var used = 0
            while end < remaining.endIndex, used + columns(remaining[end]) <= capacity {
                used += columns(remaining[end])
                end = remaining.index(after: end)
            }
            if end == remaining.startIndex { end = remaining.index(after: end) }
            let prefix = remaining[..<end]
            let breakIndex = prefix.lastIndex(of: " ") ?? prefix.endIndex
            let chunk = remaining[..<breakIndex]
            result.append(indentation + chunk)
            remaining = String(remaining[breakIndex...]).trimmingCharacters(in: .whitespaces)
        }
        result.append(indentation + remaining)
        return result
    }
}
