import CalopodCommands
import CalopodDomain
import SwiftUI

struct InboxDetailView: View {
    let model: InboxModel
    let detail: InboxDetail
    let colors: CalendarColors
    let entries: [InboxEntry]
    private let aliases = CalendarAliases.shared

    private var entry: InboxEntry { detail.entry }

    /// Below this pane width the two cards stack, details first.
    private static let twoColumnWidth: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.title).font(Theme.Fonts.sectionTitle)
            DetailColumns(threshold: Self.twoColumnWidth, spacing: 16) {
                detailsCard
                actionsCard
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Around this time").font(Theme.Fonts.sectionTitle)
                ContextStrip(detail: detail, colors: colors)
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event details").font(Theme.Fonts.sectionTitle).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 8) {
                    ForEach(entry.reasons, id: \.self) { StatusPill(text: InboxText.label($0, entry), color: InboxText.tint($0)) }
                }
                facts
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event actions").font(Theme.Fonts.sectionTitle).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                Text(detail.replyNote).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reply = model.pendingReply { confirm(reply) } else { actions }
                if let result = model.result {
                    Banner(kind: result.status == .confirmed ? .info : .caution, text: result.message)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
        }
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
            if let link = entry.meeting {
                JoinButton(link: link, prominent: MeetingLink.isNear(startsAt: entry.startsAt, endsAt: entry.endsAt)) {
                    Task { await model.joinMeeting() }
                }
                .help(JoinButton.help(for: link))
            }
            if detail.canOpenInCalendar {
                HStack(spacing: 8) {
                    Button("Open in Calendar") { model.openInCalendar() }
                        .help(CalendarOpenText.help)
                    Text("Answer it in Calendar. Calopod reads the reply on the next sync.")
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
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
    }

    private func reply(_ title: String, _ choice: ConflictChoice) -> some View {
        Button(title) { model.askToReply(choice) }
            .disabled(model.isBusy || !detail.replies.contains(choice))
    }
}

/// Two cards side by side when the pane is at least `threshold` wide, otherwise stacked.
private struct DetailColumns: Layout {
    let threshold: CGFloat
    let spacing: CGFloat

    private func columns(_ width: CGFloat) -> Bool { width >= threshold }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? threshold
        if columns(width) {
            let each = (width - spacing) / 2
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if columns(bounds.width) {
            let each = (bounds.width - spacing) / 2
            for (index, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (each + spacing), y: bounds.minY), anchor: .topLeading,
                           proposal: ProposedViewSize(width: each, height: nil))
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let height = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
                y += height + spacing
            }
        }
    }
}
