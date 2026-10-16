import CalopodCommands
import SwiftUI

struct ConflictsView: View {
    let model: ConflictModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let busy = model.busy {
                    HStack { ProgressView().controlSize(.small); Text(busy) }
                }
                if let notice = model.notice {
                    Text(notice).foregroundStyle(.red)
                }
                if let report = model.report {
                    reportView(report)
                }
                if let preview = model.preview {
                    previewView(preview)
                } else {
                    boardView
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
        .task { await model.reload() }
    }

    // MARK: Choices

    @ViewBuilder
    private var boardView: some View {
        if let board = model.board {
            if board.groups.isEmpty {
                Text(board.isComplete
                    ? "No overlapping events right now."
                    : "No overlaps found, but some calendars are out of date or only partly read, so this may be incomplete.")
                    .foregroundStyle(.secondary)
            } else {
                if !board.isComplete {
                    Label("Some calendars are out of date or only partly read. Overlaps may be missing.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("Choose what to do with each event. “No change” leaves it alone. Replies are sent only after you review them.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(board.groups) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(group.events) { event in eventRow(event) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("\(group.overlapCount) overlap\(group.overlapCount == 1 ? "" : "s")")
                            .font(.headline)
                    }
                }
                Button("Review changes…") { Task { await model.reviewChanges() } }
                    .disabled(model.isBusy || model.pendingReplies.isEmpty)
            }
        } else {
            ProgressView()
        }
    }

    private func eventRow(_ event: ConflictEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title).font(.body.bold())
            Text("\(Self.time(event)) · \(event.calendarName) · \(event.response.replacingOccurrences(of: "-", with: " "))")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = event.replyUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Action", selection: Binding(
                get: { model.choice(for: event.id) },
                set: { model.select($0, for: event.id) }
            )) {
                ForEach(event.choices, id: \.self) { Text(Self.label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy || event.choices.count == 1)
        }
    }

    // MARK: Preview

    private func previewView(_ preview: ConflictPreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review before sending").font(.title3.bold())
            ForEach(preview.replies) { reply in
                Text("Reply “\(Self.label(reply.choice))” to \(reply.title)")
            }
            Label("Replies are sent to your calendar provider and may notify the organizer.", systemImage: "paperplane")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(preview.resolvedCount) overlap\(preview.resolvedCount == 1 ? "" : "s") resolved, \(preview.remainingCount) still overlapping.")
            if preview.createdCount > 0 {
                Label("\(preview.createdCount) new overlap\(preview.createdCount == 1 ? "" : "s") would be created.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !preview.isComplete {
                Label("Some calendars are out of date, so this projection may be incomplete.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("If an event changes before it is sent, that reply is skipped and reported.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Send replies") { Task { await model.send() } }
                    .keyboardShortcut(.defaultAction)
                Button("Back") { model.backToChoices() }
            }
            .disabled(model.isBusy)
        }
    }

    // MARK: Result

    private func reportView(_ report: ConflictApplyReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.allConfirmed
                    ? "All replies were recorded."
                    : "\(report.confirmedCount) of \(report.lines.count) replies were recorded.")
                    .font(.headline)
                ForEach(report.lines) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: line.status == .confirmed ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(line.status == .confirmed ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(line.title)
                            Text(line.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Done") { model.dismissReport() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
