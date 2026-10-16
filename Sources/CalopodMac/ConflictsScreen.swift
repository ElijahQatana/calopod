import CalopodCommands
import SwiftUI

/// Overlapping events, one decision each, one combined preview, then send.
struct ConflictsScreen: View {
    let model: ConflictModel

    var body: some View {
        Form {
            if let busy = model.busy { Section { BusyLine(text: busy) } }
            if let notice = model.notice { Section { Banner(kind: .error, text: notice) } }
            if let report = model.report { reportSection(report) }
            if let preview = model.preview { previewSection(preview) } else { board }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
                    .help("Re-read your calendars. Nothing is changed.")
            }
        }
        .task { await model.reload() }
    }

    // MARK: Board

    @ViewBuilder
    private var board: some View {
        if let board = model.board {
            if !board.isComplete {
                Section {
                    Banner(kind: .caution, text: "Some calendars are out of date or only partly read, so overlaps may be missing.")
                }
            }
            if board.groups.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No overlapping events",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing on your calendars is double-booked.")
                    )
                }
            } else {
                ForEach(board.groups) { group in
                    Section {
                        ForEach(group.events) { eventRow($0) }
                    } header: {
                        Text("\(group.overlapCount) overlap\(group.overlapCount == 1 ? "" : "s")")
                    }
                }
                Section {
                    HStack {
                        Text(summary).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review changes") { Task { await model.reviewChanges() } }
                            .buttonStyle(.accentFilled)
                            .disabled(model.isBusy || model.pendingReplies.isEmpty)
                    }
                    Hint { Text("“No change” leaves an event alone. Nothing is sent until you review.") }
                }
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private var summary: String {
        let count = model.pendingReplies.count
        return count == 0 ? "No replies chosen" : "\(count) repl\(count == 1 ? "y" : "ies") ready to review"
    }

    private func eventRow(_ event: ConflictEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.headline)
                    Text("\(Self.time(event)) · \(event.calendarName)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.response.replacingOccurrences(of: "-", with: " "))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            if let reason = event.replyUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // With no reply available the only choice is "No change", so there is nothing to pick.
            if event.choices.count > 1 {
                Picker(
                    "Action",
                    selection: Binding(
                        get: { model.choice(for: event.id) },
                        set: { model.select($0, for: event.id) }
                    )
                ) {
                    ForEach(event.choices, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Preview

    private func previewSection(_ preview: ConflictPreviewSummary) -> some View {
        Group {
            Section("Review before sending") {
                ForEach(preview.replies) { reply in
                    LabeledContent(reply.title, value: Self.label(reply.choice))
                }
                LabeledContent("Result", value: "\(preview.resolvedCount) resolved · \(preview.remainingCount) still overlapping")
                if preview.createdCount > 0 {
                    Banner(
                        kind: .caution, text: "\(preview.createdCount) new overlap\(preview.createdCount == 1 ? "" : "s") would be created."
                    )
                }
                if !preview.isComplete {
                    Banner(kind: .caution, text: "Some calendars are out of date, so this may be incomplete.")
                }
            }
            Section {
                HStack {
                    Button("Back") { model.backToChoices() }
                    Spacer()
                    Button("Send replies") { Task { await model.send() } }
                        .buttonStyle(.accentFilled)
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(model.isBusy)
                Hint {
                    Text(
                        "Replies go to your calendar provider and may notify the organizer. If an event changes first, that reply is skipped."
                    )
                }
            }
        }
    }

    // MARK: Result

    private func reportSection(_ report: ConflictApplyReport) -> some View {
        Section {
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
        } header: {
            Text(
                report.allConfirmed
                    ? "All replies were recorded"
                    : "\(report.confirmedCount) of \(report.lines.count) replies were recorded")
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
