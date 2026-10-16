import CalopodCommands
import SwiftUI

/// Overlapping events, one decision each, one combined preview, then send.
struct ConflictsScreen: View {
    let model: ConflictModel

    var body: some View {
        ScreenScaffold {
            ScreenHeader(
                title: "Conflicts",
                subtitle: "Events that overlap. Decide each one, review, then send."
            ) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
                    .help("Re-read your calendars. Nothing is changed.")
            }
            BusyLine(text: model.busy)
            if let notice = model.notice { Banner(kind: .error, text: notice) }
            if let report = model.report { reportCard(report) }
            if let preview = model.preview { previewCard(preview) } else { board }
        }
        .task { await model.reload() }
    }

    // MARK: Board

    @ViewBuilder
    private var board: some View {
        if let board = model.board {
            if !board.isComplete {
                Banner(kind: .caution, text: "Some calendars are out of date or only partly read, so overlaps may be missing.")
            }
            if board.groups.isEmpty {
                Card {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 34)).foregroundStyle(Theme.good)
                        Text("No overlapping events").font(.title3.weight(.medium))
                        Text("Nothing on your calendars is double-booked.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                ForEach(board.groups) { group in groupCard(group) }
                HStack {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Review changes") { Task { await model.reviewChanges() } }
                        .buttonStyle(.accentFilled)
                        .disabled(model.isBusy || model.pendingReplies.isEmpty)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        }
    }

    private var summary: String {
        let count = model.pendingReplies.count
        return count == 0 ? "“No change” is selected for every event." : "\(count) repl\(count == 1 ? "y" : "ies") ready to review."
    }

    private func groupCard(_ group: ConflictGroup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("\(group.overlapCount) overlap\(group.overlapCount == 1 ? "" : "s")")
                ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: ConflictEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title).font(.headline)
            Text("\(Self.time(event)) · \(event.calendarName) · \(event.response.replacingOccurrences(of: "-", with: " "))")
                .font(.callout).foregroundStyle(.secondary)
            if let reason = event.replyUnavailableReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            // With no reply available the only choice is "No change", so there is nothing to pick.
            if event.choices.count > 1 {
                Picker("Action", selection: Binding(
                    get: { model.choice(for: event.id) },
                    set: { model.select($0, for: event.id) }
                )) {
                    ForEach(event.choices, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: Preview

    private func previewCard(_ preview: ConflictPreviewSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Review before sending")
                ForEach(preview.replies) { reply in
                    HStack(spacing: 8) {
                        Text(Self.label(reply.choice))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        Text(reply.title)
                    }
                }
                Text("\(preview.resolvedCount) resolved · \(preview.remainingCount) still overlapping")
                    .font(.title3.weight(.medium))
                if preview.createdCount > 0 {
                    Banner(kind: .caution, text: "\(preview.createdCount) new overlap\(preview.createdCount == 1 ? "" : "s") would be created.")
                }
                if !preview.isComplete {
                    Banner(kind: .caution, text: "Some calendars are out of date, so this may be incomplete.")
                }
                Banner(kind: .info, text: "Replies go to your calendar provider and may notify the organizer. If an event changes first, that reply is skipped.")
                HStack(spacing: 10) {
                    Button("Send replies") { Task { await model.send() } }
                        .buttonStyle(.accentFilled)
                        .keyboardShortcut(.defaultAction)
                    Button("Back") { model.backToChoices() }
                }
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: Result

    private func reportCard(_ report: ConflictApplyReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(report.allConfirmed
                    ? "All replies were recorded."
                    : "\(report.confirmedCount) of \(report.lines.count) replies were recorded.")
                    .font(.title3.weight(.medium))
                ForEach(report.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: line.status == .confirmed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(line.status == .confirmed ? Theme.good : Theme.caution)
                        VStack(alignment: .leading) {
                            Text(line.title)
                            Text(line.message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Done") { model.dismissReport() }
            }
        }
    }

    private static func label(_ choice: ConflictChoice) -> String {
        switch choice {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        case .noChange: "No change"
        }
    }

    private static func time(_ event: ConflictEvent) -> String {
        event.isAllDay
            ? event.startsAt.formatted(date: .abbreviated, time: .omitted) + ", all day"
            : event.startsAt.formatted(date: .abbreviated, time: .shortened)
                + "–" + event.endsAt.formatted(date: .omitted, time: .shortened)
    }
}
