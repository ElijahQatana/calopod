import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

struct InboxReviewTerminal {
    let controller: InboxReviewSessionController
    let refresh: InboxReviewSessionController.Refresh
    let provider: InboxReviewSessionController.Provider
    let read: () -> String?
    let write: (String) -> Void
    var width = 80
    var decoration = true
    var timezone = TimeZone.current
    var cutoff: Date { Date().addingTimeInterval(-3600) }

    func emit(_ text: String) { write(Self.safe(text, width: width)) }

    func run(_ initial: InboxReviewSession) async throws -> InboxReviewSession {
        var session = initial
        let query = InboxAttentionQuery.evaluate(session.lastSnapshot, filter: session.filter, freshnessCutoff: cutoff)
        let unavailable = query.rows.filter {
            InboxCalendarContextBuilder.choices(for: $0.item, snapshot: session.lastSnapshot).requiresManualProviderEdit
        }.count
        emit("You have \(session.queueCount) events to handle. \(query.rows.filter { !$0.conflicts.isEmpty }.count) have conflicts.\n\(unavailable) have unavailable RSVP actions. Scope: retained coverage and saved filters.\nRSVP choices send responses and may notify the organizer. Hold sends nothing.")
        for source in session.lastSnapshot.sources {
            emit("\(source.connectionLabel ?? source.provider) / \(source.calendarLabel ?? "Calendar"): \(source.coverage.map { interval($0.startsAt, $0.endsAt) + "; observed " + date($0.observedAt) } ?? "coverage unknown")\(source.staleSince != nil || source.healthStatus != "healthy" || (source.coverage?.observedAt ?? .distantPast) < cutoff ? "; stale" : "")")
        }
        emit("Queue filters: \(session.filter.excludeMaybe ? "Maybe excluded" : "Maybe included"); \(session.filter.conflictsOnly ? "conflicts only" : "all attention reasons").")
        if let window = session.filter.window { emit("Dates: " + interval(window.start, window.end)) }
        if let ids = session.filter.bindingIDs {
            let labels = session.lastSnapshot.sources.filter { ids.contains($0.bindingID) }
                .map { ($0.connectionLabel ?? $0.provider) + " / " + ($0.calendarLabel ?? "Calendar") }
            emit("Queue sources: " + labels.joined(separator: "; "))
        }
        var focusedKey: String?
        var originKey: String?
        var stopped = false
        while session.cursor < session.queueCount || focusedKey != nil {
            let key = focusedKey ?? session.entries[session.cursor].sourceKeyHash
            let card: InboxReviewCard
            do {
                guard let current = try await controller.card(sessionID: session.id, sourceKeyHash: focusedKey,
                    conflictFromKey: originKey, freshnessCutoff: cutoff, refresh: refresh, provider: provider) else { break }
                card = current
            } catch {
                let title = session.lastSnapshot.events.first { $0.event.sourceKeyHash == key }?.event.title ?? "Queued event"
                emit("\(title): card unavailable or changed. No response sent.\n[r] Refresh [h] Hold [q] Exit")
                guard let input = read() else { stopped = true; break }
                if input == "q" { stopped = true; break }
                if input == "h" {
                    do { session = try controller.deferUnavailable(sessionID: session.id, sourceKeyHash: key, freshnessCutoff: cutoff, hold: true) }
                    catch { emit("Decision remains unresolved. Exit and resume to reconcile it."); break }
                    focusedKey = nil; originKey = nil
                }
                continue
            }
            render(card, session: session)
            let choices = card.providerSnapshot == nil ? [InboxConflictChoice.hold] :
                InboxCalendarContextBuilder.choices(for: card.context.focused, snapshot: card.context.snapshot).choices
            let neighbors = card.context.conflictGroup.filter { $0.event.sourceKeyHash != key }
            emit(choices.map { "[\(Self.letter($0))] \(Self.name($0))" }.joined(separator: "  ") + "  [q] Exit")
            if !neighbors.isEmpty {
                for (index, neighbor) in neighbors.enumerated() { emit("[g\(index + 1)] Review \(neighbor.event.title ?? "Untitled")") }
            }
            if focusedKey != nil { emit("[b] Back to queue") }
            guard let input = read() else { stopped = true; break }
            if input == "q" { stopped = true; break }
            if input == "b", focusedKey != nil { focusedKey = nil; originKey = nil; continue }
            if input.hasPrefix("g"), let number = Int(input.dropFirst()), neighbors.indices.contains(number - 1) {
                originKey = key; focusedKey = neighbors[number - 1].event.sourceKeyHash; continue
            }
            guard let choice = choices.first(where: { Self.letter($0) == input }) else {
                emit("Enter one available choice, then Enter."); continue
            }
            do {
                session = try await controller.decide(choice, card: card, freshnessCutoff: cutoff, refresh: refresh, provider: provider)
                let entry = session.entries.first { $0.sourceKeyHash == key }
                switch entry?.outcome {
                case .confirmed: emit("Saved: \(Self.name(choice)).")
                case .hold: emit("Saved: Hold. Still in your inbox.")
                case .stale: emit("Event changed. Read the refreshed card and choose again."); continue
                case .unknown: emit("Outcome unknown. Saved for reconciliation; no success counted."); summary(session, stopped: true); return session
                default:
                    emit("Response failed or unavailable. No success counted. [h] Hold [q] Exit")
                    guard read() == "h" else { summary(session, stopped: true); return session }
                    session = try controller.deferUnavailable(sessionID: session.id, sourceKeyHash: key,
                        freshnessCutoff: cutoff, hold: true)
                    emit("Saved: Hold. Still in your inbox.")
                }
                focusedKey = nil; originKey = nil
            } catch is CancellationError { stopped = true; break }
            catch {
                session = try controller.session(id: session.id)
                if session.hasUnresolvedActions {
                    emit("Decision incomplete. Saved for reconciliation; no success assumed.")
                    summary(session, stopped: true)
                    return session
                }
                emit("Decision changed or could not complete. No success assumed.\nRead the refreshed card before choosing again.")
            }
        }
        session = try controller.session(id: session.id)
        summary(session, stopped: stopped || session.cursor < session.queueCount || session.hasUnresolvedActions)
        return session
    }

    func render(_ card: InboxReviewCard, session: InboxReviewSession) {
        let context = card.context
        let event = context.focused.event
        let reasons = InboxAttentionQuery.evaluate(context.snapshot, freshnessCutoff: cutoff).rows
            .first { $0.item.event.sourceKeyHash == event.sourceKeyHash }
        emit("Event \(min(session.cursor + 1, session.queueCount)) of \(session.queueCount)\n\(event.title ?? "Untitled")\n\(interval(event.startsAt, event.endsAt)) \(timezone.identifier)\(event.isAllDay ? " (all day)" : "")\nSource: \(context.source.connectionLabel ?? context.source.provider) / \(context.source.calendarLabel ?? "Calendar")\nRSVP: \(event.currentUserResponse.state.rawValue)\nReasons: \(reasons?.reasons.map { $0 == .needsResponse ? "Needs RSVP" : $0.rawValue }.joined(separator: ", ") ?? "none")")
        if reasons?.changeTiming == .uncertain { emit("Change order uncertain.") }
        if let organizer = event.organizer { emit("Organizer: \(organizer.name ?? "") \(organizer.emailAddress ?? "")") }
        emit("Availability: \(event.availability)\(event.isPrivate ? "; private" : "")")
        if event.providerSeriesID != nil { emit("Recurring invitation: this occurrence only.") }
        for attendee in event.attendees {
            emit("Attendee: \(attendee.name ?? "") \(attendee.emailAddress ?? "") \(attendee.status ?? "")")
        }
        for (label, value) in [("Location", event.location), ("Details", event.notes), ("Meeting link", event.url)] {
            if let value { emit("\(label): \(value)") }
        }
        emit("Around this event: \(interval(context.visibleWindow.start, context.visibleWindow.end))")
        for row in context.rows {
            let other = row.event.event
            let conflict = context.focusedConflicts.contains { $0.pair.contains(other.sourceKeyHash) && other.sourceKeyHash != event.sourceKeyHash }
            emit("\(interval(other.startsAt, other.endsAt)) \(other.title ?? "Untitled") | \(row.source.connectionLabel ?? row.source.provider) / \(row.source.calendarLabel ?? "Calendar")\(row.isFocused ? " <- this event" : conflict ? " CONFLICT" : "")")
        }
        for projection in context.projections where projection.choice == .yes || projection.choice == .maybe {
            for conflict in projection.conflicts {
                let otherKey = conflict.pair.first == event.sourceKeyHash ? conflict.pair.second : conflict.pair.first
                let other = context.snapshot.events.first { $0.event.sourceKeyHash == otherKey }?.event
                emit("\(Self.name(projection.choice)) overlaps \(other?.title ?? "another event"): \(interval(conflict.overlap.start, conflict.overlap.end)) (\(conflict.overlap.end.timeIntervalSince(conflict.overlap.start)) seconds).")
            }
        }
        if !context.analysis.warnings.isEmpty { emit("Context limits: \(Set(context.analysis.warnings.map { $0.kind.rawValue }).sorted().joined(separator: ", ")). Conflicts may be incomplete.") }
        let limits = event.currentUserResponse.limits.map(\.rawValue) +
            InboxCalendarContextBuilder.choices(for: context.focused, snapshot: context.snapshot).unavailableReasons.map(\.rawValue)
        if !limits.isEmpty { emit("Action limits: " + limits.joined(separator: ", ")) }
        if card.providerSnapshot == nil { emit("RSVP unavailable or provider preview failed. Use Hold or the provider app.") }
        if context.source.provider == "eventkit", card.providerSnapshot == nil {
            emit("Open in Calendar: answer this invitation in the Calendar app. Calopod reads your answer on the next sync. Hold skips it for now.")
        }
        if context.source.provider == "microsoft" { emit("Provider revision checks are preflight only; concurrent changes cannot be prevented atomically.") }
    }

    func summary(_ session: InboxReviewSession, stopped: Bool) {
        guard let totals = session.summary else {
            emit("Progress saved. Run calopod inbox review --resume to reconcile and continue."); return
        }
        emit("\(totals.queueReviewed ? "Queue reviewed." : "Queue paused.") \(totals.inboxResolved ? "Inbox resolved." : "Inbox still has outstanding items.")\nYes: \(totals.yes)  No: \(totals.no)  Maybe: \(totals.maybe)  Hold: \(totals.hold)\nFailed: \(totals.failed)  Unknown: \(totals.unknown)  Unavailable: \(totals.unavailable)  Changed: \(totals.stale)\nConflicts created: \(totals.createdConflicts)\(totals.attributionIsComplete ? "" : " (attribution incomplete)")\nRemaining conflicts: \(totals.remainingConflicts)\(totals.contextIsComplete ? "" : " (context incomplete)")\nRemaining queue: \(totals.remainingQueueItems)  Inbox items: \(totals.remainingInboxItems)")
        if stopped {
            if totals.queueReviewed && !session.hasUnresolvedActions {
                emit("Progress saved. This queue is reviewed.\nStart calopod inbox review for remaining items.")
            } else { emit("Progress saved. Run calopod inbox review --resume to continue.") }
        }
        else { emit(Self.celebration(totals.yes + totals.no + totals.maybe, decoration: decoration, width: width)) }
    }

    func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    func interval(_ start: Date, _ end: Date) -> String { "\(date(start)) to \(date(end))" }
    static func letter(_ choice: InboxConflictChoice) -> String {
        switch choice { case .yes: "y"; case .no: "n"; case .maybe: "m"; case .hold: "h" }
    }
    static func name(_ choice: InboxConflictChoice) -> String { choice.rawValue.capitalized }
    static func safe(_ text: String, width: Int) -> String {
        let escaped = text.unicodeScalars.map { scalar -> String in
            if scalar.value == 10 { return "\n" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
        return escaped.components(separatedBy: "\n").flatMap { line -> [String] in
            if line.isEmpty { return [""] }
            var result: [String] = []
            var remaining = Array(line)
            while !remaining.isEmpty {
                var columns = 0, end = 0
                for character in remaining {
                    let size = character.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1
                    if columns + size > max(1, width), end > 0 { break }
                    columns += size; end += 1
                }
                if end < remaining.count, let space = remaining[..<end].lastIndex(of: " "), space > 0 {
                    result.append(String(remaining[..<space]))
                    remaining.removeFirst(space + 1)
                } else {
                    result.append(String(remaining[..<end]))
                    remaining.removeFirst(end)
                }
            }
            return result
        }.joined(separator: "\n")
    }
    static func celebration(_ count: Int, decoration: Bool, width: Int) -> String {
        guard count > 0 else { return "Thanks for reviewing. No responses sent this session." }
        guard decoration, width >= 16 else { return "Thanks for reviewing. \(count) confirmed responses." }
        if count <= 5 { return "Tiny squid approves!\n  (o_o)\n ~||||~" }
        if count <= 20 { return "Party squid!\n  \\o/\n ~(o_o)~\n /| | |\\" }
        return "Release the kraken!\n   ___\n  (o_o)\n /|||||\\\n~|||||||~"
    }
}
