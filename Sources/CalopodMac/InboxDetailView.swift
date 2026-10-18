import CalopodCommands
import SwiftUI

struct InboxDetailView: View {
    let model: InboxModel
    let detail: InboxDetail
    let colors: CalendarColors
    let entries: [InboxEntry]
    private let aliases = CalendarAliases.shared

    private var entry: InboxEntry { detail.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.title).font(Theme.Fonts.sectionTitle)
            FlowLayout(spacing: 8) {
                ForEach(entry.reasons, id: \.self) { StatusPill(text: InboxText.label($0, entry), color: InboxText.tint($0)) }
            }
            facts
            VStack(alignment: .leading, spacing: 6) {
                Text("Around this time").font(Theme.Fonts.bodySemibold)
                ContextStrip(detail: detail, colors: colors)
            }
            Text(detail.replyNote).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reply = model.pendingReply { confirm(reply) } else { actions }
            if let result = model.result {
                Banner(kind: result.status == .confirmed ? .info : .caution, text: result.message)
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            fact("When", entry.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", " + InboxText.time(entry))
            if let place = entry.location, !place.isEmpty { fact("Where", place) }
            if let organizer = entry.organizer { fact("Organizer", organizer) }
            GridRow {
                Text("Calendar").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle().fill(colors.color(for: entry.calendarID).color).frame(width: 9, height: 9)
                    Text(aliases.name(for: entry.calendarID, real: entry.calendarName))
                }
            }
        }
        .font(Theme.Fonts.body)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                reply("Yes", .yes)
                reply("Maybe", .maybe)
                reply("No", .no)
                Button("Hold") { model.hold(in: entries) }
                    .help("Skip for now. Nothing is sent or marked.")
            }
            if entry.canAcknowledge {
                HStack(spacing: 8) {
                    Button("Acknowledge") { Task { await model.acknowledge(entry) } }
                        .disabled(model.isBusy)
                    Text("Marks this edit as seen on this Mac. No reply is sent.")
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.large)
    }

    private func confirm(_ reply: ConflictChoice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ReplyConfirmView(confirmation: ReplyConfirmation(detail: detail, reply: reply))
            HStack {
                Button("Cancel") { model.cancelReply() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send \(InboxReviewModel.name(reply))") { Task { await model.confirmReply() } }
                    .buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(14)
        .cardSurface()
    }

    private func reply(_ title: String, _ choice: ConflictChoice) -> some View {
        Button(title) { model.askToReply(choice) }
            .disabled(model.isBusy || !detail.replies.contains(choice))
    }
}
