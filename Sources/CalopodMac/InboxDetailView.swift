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

/// The event and its neighbors on a shared time axis. Anything that overlaps it is ringed.
struct ContextStrip: View {
    let detail: InboxDetail
    let colors: CalendarColors

    private let laneHeight: CGFloat = 32
    /// Short events are drawn at least this share of the strip so a title stays readable.
    private static let minShare = 0.3

    var body: some View {
        let span = max(detail.windowEnd.timeIntervalSince(detail.windowStart), 1)
        let lanes = assignLanes(span: span)
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(detail.context) { item in
                        let x = max(0, item.startsAt.timeIntervalSince(detail.windowStart) / span) * proxy.size.width
                        let width = max(Self.minShare * proxy.size.width, min(1, item.endsAt.timeIntervalSince(detail.windowStart) / span) * proxy.size.width - x)
                        block(item)
                            .frame(width: width, height: laneHeight - 4)
                            .offset(x: min(x, max(0, proxy.size.width - width)), y: CGFloat(lanes[item.id] ?? 0) * laneHeight)
                    }
                }
            }
            .frame(height: CGFloat((lanes.values.max() ?? 0) + 1) * laneHeight)
            HStack {
                Text(detail.windowStart.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(detail.windowEnd.formatted(date: .omitted, time: .shortened))
            }
            .font(Theme.Fonts.tiny).foregroundStyle(.secondary)
        }
        .padding(10)
        .cardSurface()
    }

    private func block(_ item: InboxContextEntry) -> some View {
        let color = colors.color(for: item.calendarID).color
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Text(item.title)
            .font(Theme.Fonts.tiny.weight(item.isFocused ? .bold : .regular))
            .lineLimit(1).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(color.opacity(item.isFocused ? 0.45 : 0.22)))
            .overlay(shape.strokeBorder(item.overlapsFocused ? Theme.bad : color.opacity(item.isFocused ? 1 : 0.5),
                                        lineWidth: item.overlapsFocused || item.isFocused ? 2 : 1))
            .help(item.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title + (item.overlapsFocused ? ", overlaps" : item.isFocused ? ", this event" : ""))
    }

    /// Places each block in the first row where it does not collide.
    private func assignLanes(span: TimeInterval) -> [String: Int] {
        var ends: [Date] = []
        var result: [String: Int] = [:]
        for item in detail.context.sorted(by: { $0.startsAt < $1.startsAt }) {
            let lane = ends.firstIndex { $0 <= item.startsAt } ?? ends.count
            let end = max(item.endsAt, item.startsAt.addingTimeInterval(span * Self.minShare))
            if lane == ends.count { ends.append(end) } else { ends[lane] = end }
            result[item.id] = lane
        }
        return result
    }
}
