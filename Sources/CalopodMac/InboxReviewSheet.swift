import CalopodCommands
import SwiftUI

/// Goes through the inbox one event at a time. Everything is keyboard driven.
struct InboxReviewSheet: View {
    let model: InboxReviewModel
    let colors: CalendarColors
    let close: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let notice = model.notice, showsNotice { Banner(kind: .info, text: notice) }
            content
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 460)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            let text = press.key == .return ? ReviewKeyboard.returnKey : press.key == .escape ? ReviewKeyboard.escapeKey : press.characters
            // Only keys the review uses are taken, so Esc still closes the sheet from a card.
            guard let key = model.interpret(text) else { return .ignored }
            Task { await model.perform(key) }
            return .handled
        }
    }

    private var showsNotice: Bool {
        switch model.phase {
        case .card, .problem: true
        default: false
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Review inbox").font(Theme.title())
                Spacer()
                if case .summary = model.phase {
                    Button("Close", action: close).buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
                } else if case .start = model.phase {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                } else {
                    Button("Stop") { model.stop() }.help("Stop here. Your progress is saved. (S)")
                }
            }
            if let progress = model.progress, showsProgress {
                bar(Double(progress.reviewed) / Double(max(progress.total, 1)))
                Text(progressLine(progress)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        Capsule().fill(.quaternary).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Theme.accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Review progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private var showsProgress: Bool {
        if case .start = model.phase { return false }
        return true
    }

    private func progressLine(_ progress: InboxReviewProgress) -> String {
        if case .card(let card) = model.phase { return "Event \(card.position) of \(card.total) · \(progress.reviewed) done" }
        if case .confirm(let card, _) = model.phase { return "Event \(card.position) of \(card.total) · \(progress.reviewed) done" }
        return "\(progress.reviewed) of \(progress.total) done"
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .start: start
        case .working(let text):
            BusyLine(text: text).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .card(let card): cardView(card)
        case .confirm(let card, let reply): confirmView(card, reply)
        case .problem(let text, _): problem(text)
        case .summary: summary
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = model.saved {
                Banner(kind: .info, text: saved.hasUnclear
                    ? "A reply from your last review has an unclear outcome. Resume checks what happened first and never sends it again."
                    : "You have a review in progress: \(saved.reviewed) of \(saved.total) done.")
                HStack {
                    Button("Resume") { Task { await model.resume() } }
                        .buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
                    if !saved.hasUnclear { Text("or start a new one below").foregroundStyle(.secondary) }
                }
            }
            if model.saved?.hasUnclear != true {
                Toggle("Only events that overlap something", isOn: Binding(get: { model.overlapsOnly }, set: { model.overlapsOnly = $0 }))
                Toggle("Leave out events I answered Maybe", isOn: Binding(get: { model.skipMaybe }, set: { model.skipMaybe = $0 }))
                Hint { Text("Yes, Maybe and No send your reply to the calendar and may notify the organizer. Hold sends nothing. Keys: Y, N, M, H, G then a number, S to stop.") }
                if model.saved == nil {
                    Button("Start review") { Task { await model.begin() } }
                        .buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
                } else {
                    Button("Start a new review") { Task { await model.begin() } }
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.large)
    }

    private func cardView(_ card: InboxReviewCardInfo) -> some View {
        let entry = card.entry
        return VStack(alignment: .leading, spacing: 14) {
                Text(entry.title).font(Theme.title(.title3))
                HStack(spacing: 8) {
                    ForEach(entry.reasons, id: \.self) { StatusPill(text: InboxText.label($0, entry), color: InboxText.tint($0)) }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    fact("When", entry.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", " + InboxText.time(entry))
                    if let place = entry.location, !place.isEmpty { fact("Where", place) }
                    if let organizer = entry.organizer { fact("Organizer", organizer) }
                    fact("Calendar", card.account)
                }
                .font(.callout)
                Text("Around this time").font(.headline)
                ContextStrip(detail: card.detail, colors: colors)
                if card.replies.isEmpty {
                    Text(card.detail.replyNote).font(.callout).foregroundStyle(.secondary)
                }
                actions(card)
                if !card.neighbors.isEmpty { neighbors(card) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func actions(_ card: InboxReviewCardInfo) -> some View {
        HStack(spacing: 8) {
            reply("Yes", "Y", .yes, card)
            reply("Maybe", "M", .maybe, card)
            reply("No", "N", .no, card)
            Button("Hold  H") { Task { await model.perform(.hold) } }
                .help("Skip it for this session. Nothing is sent or marked.")
        }
        .controlSize(.large)
    }

    private func reply(_ title: String, _ key: String, _ choice: ConflictChoice, _ card: InboxReviewCardInfo) -> some View {
        Button("\(title)  \(key)") { Task { await model.perform(.reply(choice)) } }
            .disabled(!card.replies.contains(choice))
    }

    private func neighbors(_ card: InboxReviewCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Overlaps with").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(card.neighbors.enumerated()), id: \.element.id) { index, other in
                Button { Task { await model.perform(.goTo(index + 1)) } } label: {
                    Text("G\(index + 1)  \(other.title)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if model.isJumped {
                Button("Back to the queue  B") { Task { await model.perform(.back) } }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func confirmView(_ card: InboxReviewCardInfo, _ reply: ConflictChoice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this reply?").font(Theme.title(.title3))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                fact("Event", card.entry.title)
                fact("Told", card.organizer ?? "The organizer")
                fact("Answer", InboxReviewModel.name(reply))
                fact("Sent through", card.account)
                let overlaps = card.preview(for: reply)?.overlaps ?? []
                fact("Overlaps after", overlaps.isEmpty ? "None" : overlaps.joined(separator: ", "))
            }
            .font(.callout)
            Banner(kind: .caution, text: (card.notification ?? "The organizer may be notified.") + " This cannot be unsent.")
            HStack {
                Button("Send  ⏎") { Task { await model.perform(.send) } }
                    .buttonStyle(.accentFilled)
                Button("Back  Esc") { Task { await model.perform(.cancel) } }
            }
            .controlSize(.large)
            Spacer(minLength: 0)
        }
    }

    private func problem(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Banner(kind: .caution, text: text)
            HStack {
                Button("Refresh  R") { Task { await model.perform(.refresh) } }
                Button("Hold  H") { Task { await model.perform(.hold) } }
                    .help("Skip it for this session. Nothing is sent.")
            }
            .controlSize(.large)
            Spacer(minLength: 0)
        }
    }

    private var summary: some View { ReviewSummary(progress: model.progress, paused: model.paused) }
}

struct ReviewSummary: View {
    let progress: InboxReviewProgress?
    let paused: Bool

    var body: some View {
        let totals = progress?.totals
        return VStack(alignment: .leading, spacing: 14) {
            if let totals {
                Text(heading(progress, totals)).font(Theme.title(.title3))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                    count("Replies recorded", totals.recorded, detail: "Yes \(totals.yes) · Maybe \(totals.maybe) · No \(totals.no)")
                    count("Held", totals.held)
                    count("Outcome unclear", totals.unclear, tint: totals.unclear > 0 ? Theme.caution : nil)
                    if totals.failed + totals.unavailable + totals.changed > 0 {
                        count("Not sent", totals.failed + totals.unavailable + totals.changed)
                    }
                    Divider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                    count("Overlaps resolved", totals.overlapsResolved)
                    count("New overlaps created", totals.overlapsCreated, tint: totals.overlapsCreated > 0 ? Theme.bad : nil)
                    count("Overlaps left", totals.overlapsRemaining)
                }
                .font(.callout)
                if !totals.overlapsAreComplete {
                    Hint { Text("Some calendars were out of date or only partly read, so the overlap counts may be low.") }
                }
                if progress?.hasUnclear == true {
                    Banner(kind: .caution, text: "A reply has an unclear outcome. It is never sent again. Choose Resume next time to check what happened.")
                } else if totals.queueReviewed {
                    Text(totals.inboxResolved ? "Your inbox is clear." : "Everything in this queue was looked at, but \(totals.remainingInbox) item\(totals.remainingInbox == 1 ? "" : "s") still need\(totals.remainingInbox == 1 ? "s" : "") attention.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Your progress is saved. Choose Review, then Resume, to carry on.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func heading(_ progress: InboxReviewProgress?, _ totals: InboxReviewTotals) -> String {
        if paused { return "Paused" }
        return totals.queueReviewed ? "Queue reviewed" : "Review paused"
    }

    private func count(_ label: String, _ value: Int, detail: String? = nil, tint: Color? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text("\(value)").monospacedDigit().fontWeight(.semibold).foregroundStyle(tint ?? .primary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) } else { Color.clear.frame(width: 0, height: 0) }
        }
    }
}
