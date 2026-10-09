@testable import CalopodCommands
import CalopodStore
import CalopodDomain
import Foundation
import Testing

@Suite("Human command output")
struct HumanOutputTests {
    @Test("Arm relationships resolve labels, retain multiple sources, and offer exact IDs")
    func armRelationships() throws {
        let id = "arm-0123456789-abcdefghij"
        let payload = CommandPayload(status: "ok", message: "Configured Arms.", count: 1, items: [
            CommandItem(id: id, kind: "arm", label: "Office hours", sourceIDs: ["source-a", "source-b"],
                        targetID: "target", rule: "full-details", enabled: false),
        ])
        let context = HumanOutputContext(calendarLabels: ["source-a": "Work", "source-b": "Personal", "target": "Combined"])
        let output = try OutputRenderer.render(command: "arm.list", payload: payload, format: .human, human: context)
        for text in ["Office hours", "Sources: 2", "Work", "Personal", "Destination: Combined", "Rule: Full details", "State: disabled", "--ids"] {
            #expect(output.contains(text))
        }
        #expect(!output.contains(id))
        let exact = try OutputRenderer.render(command: "arm.inspect", payload: payload, format: .human, showIDs: true, human: context, width: 20)
        #expect(exact.split(separator: "\n").contains("  ID: \(id)"))
        #expect(exact.contains("Source ID: source-a"))
        #expect(exact.contains("Source ID: source-b"))
        #expect(exact.contains("Destination ID: target"))
    }

    @Test("Main and unnamed Arms have readable fallbacks without hiding missing calendars")
    func fallbacks() throws {
        let payload = CommandPayload(status: "ok", message: "Configured Arms.", items: [
            CommandItem(id: "unnamed", kind: "arm", sourceIDs: ["missing"], targetID: "missing-target", rule: "busy", enabled: true),
            CommandItem(id: "main", kind: "main-calendar", label: "", sourceIDs: [], rule: "full-details", enabled: true),
        ])
        for command in ["arm.list", "main.inspect"] {
            let output = try OutputRenderer.render(command: command, payload: payload, format: .human)
            #expect(output.contains("Unnamed Arm"))
            #expect(output.contains("Main calendar"))
            #expect(output.contains("Unknown calendar"))
            #expect(!output.contains("missing-target"))
        }
    }

    @Test("Local context resolves cached labels and preserves Connection state")
    func cachedLabels() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "eventkit", displayLabel: "Example account", isEnabled: false))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: [
            StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "synthetic-provider", displayLabel: "Example calendar", isSelected: true, isReadOnly: false),
        ])
        let context = try OutputOptions.parse([]).localContext(repository: repository)
        #expect(context.calendarLabels["calendar"] == "Example calendar")
        let payload = CommandPayload(status: "ok", message: "Configured Connections.", items: [
            CommandItem(id: "connection", kind: "eventkit", label: "Example account"),
        ])
        let output = try OutputRenderer.render(command: "connection.list", payload: payload, format: .human, human: context)
        #expect(output.contains("Example account"))
        #expect(output.contains("Provider: eventkit"))
        #expect(output.contains("State: disabled"))
    }

    @Test("Calendar output shows selection, access, account, and Connection")
    func calendars() throws {
        let payload = CommandPayload(status: "ok", message: "Selectable calendars.", items: [
            CommandItem(id: "calendar-id", kind: "calendar", label: nil, parentID: "connection-id", selected: false, readOnly: true, sourceType: "caldav", sourceLabel: "Example account"),
        ])
        let output = try OutputRenderer.render(command: "calendars", payload: payload, format: .human, showIDs: true, human: HumanOutputContext(connectionLabels: ["connection-id": "On this Mac"]))
        for text in ["Unnamed calendar", "Selected: no", "Access: read only", "Account: Example account", "Connection: On this Mac", "Connection ID: connection-id", "ID: calendar-id"] {
            #expect(output.contains(text))
        }
    }

    @Test("Only event inspection shows event titles and associates each event with its source")
    func eventPrivacy() throws {
        let payload = CommandPayload(status: "partial", message: "Events in the requested range.", sources: [
            CommandSource(id: "source", connectionID: "connection", provider: "eventkit", label: "Example calendar"),
        ], items: [CommandItem(id: "private-event-id", kind: "event", label: "Synthetic appointment", parentID: "source", startsAt: "2026-10-09T09:00:00Z", endsAt: "2026-10-09T10:00:00Z", allDay: true, cancelled: true, availability: "busy")])
        let events = try OutputRenderer.render(command: "events", payload: payload, warnings: ["Cached results may be stale."], format: .human)
        for text in ["Status: partial", "Synthetic appointment", "Calendar: Example calendar", "All day: yes", "Cancelled: yes", "Warning: Cached results"] {
            #expect(events.contains(text))
        }
        #expect(!events.contains("private-event-id"))
        let availability = try OutputRenderer.render(command: "availability", payload: payload, format: .human)
        #expect(!availability.contains("Synthetic appointment"))
        #expect(availability.contains("busy"))
    }

    @Test("Sync previews and results show counts and never source event content")
    func syncCounts() throws {
        let items = ["create", "create", "update", "remove", "repair", "no-op"].map {
            CommandItem(id: "private-id", kind: $0, label: "Private title", startsAt: "private-schedule", reason: "target-matches", armID: "private-arm", mirrorKey: "private-mirror")
        }
        for mode in ["dry-run", "apply"] {
            let payload = CommandPayload(status: "partial", message: "Synchronization result.", count: 6, mode: mode, items: items)
            let output = try OutputRenderer.render(command: "sync", payload: payload, format: .human, showIDs: true, human: HumanOutputContext(applied: 4, reconciled: 1, noOps: 1))
            for text in ["Status: partial", "Planned operations: 6", "Create: 2", "Update: 1", "Remove: 1", "Repair: 1", "Already matching: 1"] { #expect(output.contains(text)) }
            for text in ["Private title", "private-id", "private-schedule", "private-arm", "private-mirror"] { #expect(!output.contains(text)) }
            if mode == "dry-run" {
                #expect(output.contains("Preview (no calendar writes)"))
                #expect(output.contains("Applied changes: 0 (preview)"))
            } else {
                #expect(output.contains("Applied changes: 4"))
                #expect(output.contains("Local reconciliations: 1"))
                #expect(output.contains("No-ops: 1"))
            }
        }
    }

    @Test("Ingestion and reconciliation summaries expose counts without private content")
    func syncReviewPrivacy() throws {
        let payload = CommandPayload(
            status: "ok", message: "Dry-run synchronization plan.", mode: "dry-run",
            items: [CommandItem(id: "private-id", kind: "remove", label: "Private event", parentID: "private-hash", reason: "source-missing", armID: "private-arm")],
            ingestion: EventIngestionSummary(excludedMarkedCopyCount: 2, excludedMappedCopyCount: 1, outOfRangeCount: 3),
            review: SyncReviewSummary(recurringOccurrenceCreateCount: 4, legacyRecurringRemovalCandidateCount: 1, staleMappingCleanupCount: 2)
        )
        let human = try OutputRenderer.render(command: "sync", payload: payload, format: .human, showIDs: true)
        for expected in ["Excluded marked copies: 2", "Excluded mapped copies: 1", "Invalid identities: 0", "Outside requested window: 3", "Recurring occurrence creates: 4", "Legacy recurring removal candidates: 1", "Stale mapping cleanup: 2", "counts do not prove source cancellation"] {
            #expect(human.contains(expected))
        }
        #expect(!human.contains("private-"))
        #expect(!human.contains("Private event"))
        let json = try OutputRenderer.render(command: "sync", payload: payload, format: .json)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["items"] != nil)
        #expect(data["mode"] as? String == "dry-run")
        for field in ["ingestion", "review"] {
            let summary = try #require(data[field] as? [String: Any])
            #expect(summary.values.allSatisfy { $0 is Int })
            #expect(!String(describing: summary).contains("private-"))
        }
        let legacy = try OutputRenderer.render(command: "sync", payload: CommandPayload(status: "ok", message: "Done."), format: .json)
        #expect(!legacy.contains("ingestion"))
        #expect(!legacy.contains("review"))
    }

    @Test("Empty results and no-ops are explicit")
    func emptyResults() throws {
        for command in ["connection.list", "calendars", "arm.list", "main.inspect", "events", "availability"] {
            let output = try OutputRenderer.render(command: command, payload: CommandPayload(status: "ok", message: "No results.", count: 0, items: []), format: .human)
            #expect(output == "No results.\nStatus: ok\nCount: 0")
        }
        let output = try OutputRenderer.render(command: "sync", payload: CommandPayload(status: "ok", message: "Managed events already match the requested state.", mode: "apply", items: [CommandItem(id: "one", kind: "no-op")]), format: .human, human: HumanOutputContext(applied: 0, reconciled: 0, noOps: 1))
        #expect(output.contains("Applied changes: 0"))
        #expect(output.contains("No-ops: 1"))
    }

    @Test("Shared diagnostics ignore private context, labels, and event details even with IDs requested")
    func sharedDiagnostics() throws {
        let payload = CommandPayload(status: "failed", message: "Health needs attention.", items: [
            CommandItem(id: "database", kind: "failed", label: "Private label", sourceIDs: ["private-source"], targetID: "private-target", reason: "local-state", armID: "private-arm"),
        ], installed: true, enabled: false, paused: true, failureCategory: "local-state", planned: 2, applied: 0, creates: 1, noOps: 1, connectionCount: 2, armCount: 3, backupValid: true, migrationCount: 8)
        for command in ["doctor", "support.export", "support.backup", "support.verify", "support.restore", "agent.status", "agent.run-now", "agent.pause", "agent.resume", "agent.install", "agent.enable", "agent.disable", "agent.remove"] {
            let output = try OutputRenderer.render(command: command, payload: payload, format: .human, showIDs: true, human: HumanOutputContext(calendarLabels: ["private-source": "Private calendar"]))
            #expect(output.contains("Status: failed"))
            #expect(output.contains("Enabled: no"))
            #expect(output.contains("Paused: yes"))
            #expect(!output.contains("Private"))
            #expect(!output.contains("private-"))
            #expect(!output.contains("--ids"))
        }
    }

    @Test("Long labels wrap in narrow terminals and control sequences stay plain")
    func narrowOutput() throws {
        let label = "Example calendar " + String(repeating: "long ", count: 35) + "\u{1b}[31mEnd\nNext"
        let output = try OutputRenderer.render(command: "calendars", payload: CommandPayload(status: "ok", message: "Selectable calendars.", items: [CommandItem(id: "exact-identifier-with-no-truncation", kind: "calendar", label: label)]), format: .human, width: 32)
        #expect(output.split(separator: "\n").allSatisfy { $0.count <= 32 })
        #expect(!output.contains("\u{1b}"))
        #expect(output.contains("Next"))
        #expect(!output.contains("exact-identifier"))
    }

    @Test("Wide characters and very narrow terminals keep labels readable")
    func wideLabels() throws {
        let payload = CommandPayload(status: "ok", message: "Calendars.", items: [
            CommandItem(id: "synthetic", kind: "calendar", label: String(repeating: "予定", count: 12)),
        ])
        let output = try OutputRenderer.render(command: "calendars", payload: payload, format: .human, width: 16)
        #expect(output.contains("予定予定予定予定"))
        #expect(!output.contains(String(repeating: "予定", count: 5)))
        #expect(output.split(separator: "\n").allSatisfy { $0.count <= 16 })
    }

    @Test("Presentation context, width, and IDs do not change JSON")
    func jsonContract() throws {
        let payload = CommandPayload(status: "ok", message: "Done.", count: 1, items: [CommandItem(id: "exact-id", kind: "arm", label: "Office")])
        let original = try OutputRenderer.render(command: "arm.list", payload: payload, format: .json)
        let contextual = try OutputRenderer.render(command: "arm.list", payload: payload, format: .json, showIDs: true, human: HumanOutputContext(calendarLabels: ["private": "Private label"], applied: 3), width: 20)
        #expect(original == contextual)
        #expect(original == "{\"command\":\"arm.list\",\"data\":{\"count\":1,\"items\":[{\"id\":\"exact-id\",\"kind\":\"arm\",\"label\":\"Office\"}],\"message\":\"Done.\",\"status\":\"ok\"},\"schemaVersion\":1,\"warnings\":[]}")
        let options = try OutputOptions.parse(["--ids", "--format", "json"])
        #expect(options.ids)
        #expect(options.format == .json)
    }
}
