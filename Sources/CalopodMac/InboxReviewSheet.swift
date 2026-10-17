import CalopodCommands
import SwiftUI

/// Goes through the inbox one event at a time. Everything is keyboard driven.
/// The header and footer stay in place; only the middle scrolls, and only when it has to.
struct InboxReviewSheet: View {
    let model: InboxReviewModel
    let colors: CalendarColors
    let close: () -> Void
    private let aliases = CalendarAliases.shared

    @FocusState private var focused: Bool
    @State private var bodyHeight: CGFloat = 0

    private static let width: CGFloat = 640
    /// Fits a 580 pt window with the header and footer around it.
    private static let maxBodyHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            Divider()
            scrollingBody
            if let footer = footerContent {
                Divider()
                footer.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .frame(width: Self.width)
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

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = model.notice, showsNotice { Banner(kind: .info, text: notice) }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { Color.clear.preference(key: BodyHeightKey.self, value: $0.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
        .frame(height: min(max(bodyHeight, 260), Self.maxBodyHeight))
    }

    private var showsNotice: Bool {
        switch model.phase {
        case .card, .problem: true
        default: false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("Review inbox").font(Theme.Fonts.heading)
            Spacer(minLength: 8)
            if let progress = model.progress, showsProgress {
                Text(progressLine(progress)).font(Theme.Fonts.secondary).foregroundStyle(.secondary).lineLimit(1)
                bar(Double(progress.reviewed) / Double(max(progress.total, 1))).frame(width: 120)
                if showsStop { Button("Stop") { model.stop() }.help("Stop here. Your progress is saved. (S)") }
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

    private var showsStop: Bool {
        switch model.phase {
        case .start, .summary: false
        default: true
        }
    }

    private func progressLine(_ progress: InboxReviewProgress) -> String {
        if case .card(let card) = model.phase { return "Event \(card.position) of \(card.total) · \(progress.reviewed) reviewed" }
        if case .confirm(let card, _) = model.phase { return "Event \(card.position) of \(card.total) · \(progress.reviewed) reviewed" }
        return "\(progress.reviewed) of \(progress.total) reviewed"
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .start: start
        case .working(let text):
            BusyLine(text: text).frame(maxWidth: .infinity, minHeight: 160)
        case .card(let card): cardView(card)
        case .confirm(let card, let reply): confirmView(card, reply)
        case .problem(let text, _): Banner(kind: .caution, text: text)
        case .summary: ReviewSummary(progress: model.progress, paused: model.paused, calendarSkips: model.calendarSkips)
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = model.saved {
                Banner(kind: .info, text: saved.hasUnclear
                    ? "A reply from your last review has an unclear outcome. Resume checks what happened first and never sends it again."
                    : "You have a review in progress: \(saved.reviewed) of \(saved.total) done.")
            }
            if model.saved?.hasUnclear != true {
                Toggle("Only events that overlap something", isOn: Binding(get: { model.overlapsOnly }, set: { model.overlapsOnly = $0 }))
                Toggle("Leave out events I answered Maybe", isOn: Binding(get: { model.skipMaybe }, set: { model.skipMaybe = $0 }))
                Hint { Text("Yes, Maybe and No send your reply to the calendar and may notify the organizer. Hold sends nothing. Keys: Y, N, M, H, G then a number, S to stop.") }
            }
        }
        .controlSize(.large)
    }

    /// The account and calendar, with the calendar's local name when there is one.
    private func account(_ card: InboxReviewCardInfo) -> String {
        guard let alias = aliases.alias(for: card.entry.calendarID) else { return card.account }
        return "\(card.connection) / \(alias)"
    }

    private func cardView(_ card: InboxReviewCardInfo) -> some View {
        let entry = card.entry
        return VStack(alignment: .leading, spacing: 14) {
            Text(entry.title).font(Theme.Fonts.sectionTitle).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(entry.reasons, id: \.self) { StatusPill(text: InboxText.label($0, entry), color: InboxText.tint($0)) }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                fact("When", entry.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", " + InboxText.time(entry))
                if let place = entry.location, !place.isEmpty { fact("Where", place) }
                if let organizer = entry.organizer { fact("Organizer", organizer) }
                fact("Calendar", account(card))
            }
            .font(Theme.Fonts.body)
            VStack(alignment: .leading, spacing: 6) {
                Text("Around this time").font(Theme.Fonts.bodySemibold)
                ContextStrip(detail: card.detail, colors: colors)
            }
            if !card.neighbors.isEmpty { neighbors(card) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func neighbors(_ card: InboxReviewCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Overlaps with").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            ForEach(Array(card.neighbors.enumerated()), id: \.element.id) { index, other in
                Button { Task { await model.perform(.goTo(index + 1)) } } label: {
                    Text("G\(index + 1)  \(other.title)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if model.isJumped {
                Button("Back to the queue  B") { Task { await model.perform(.back) } }
                    .buttonStyle(.link).font(Theme.Fonts.secondary)
            }
        }
    }

    private func confirmView(_ card: InboxReviewCardInfo, _ reply: ConflictChoice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this reply?").font(Theme.Fonts.sectionTitle)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                fact("Event", card.entry.title)
                fact("Told", card.organizer ?? "The organizer")
                fact("Answer", InboxReviewModel.name(reply))
                fact("Sent through", account(card))
                let overlaps = card.preview(for: reply)?.overlaps ?? []
                fact("Overlaps after", overlaps.isEmpty ? "None" : overlaps.joined(separator: ", "))
            }
            .font(Theme.Fonts.body)
            Banner(kind: .caution, text: (card.notification ?? "The organizer may be notified.") + " This cannot be unsent.")
        }
    }

    // MARK: Footer

    private var footerContent: AnyView? {
        switch model.phase {
        case .start: AnyView(startFooter)
        case .working: nil
        case .card(let card): AnyView(cardFooter(card))
        case .confirm:
            AnyView(HStack {
                Button { Task { await model.perform(.cancel) } } label: { keyed("Back", "Esc") }
                Spacer()
                Button { Task { await model.perform(.send) } } label: { keyed("Send", "⏎") }.buttonStyle(.accentFilled)
            })
        case .problem:
            AnyView(HStack {
                Button { Task { await model.perform(.refresh) } } label: { keyed("Refresh", "R") }
                Spacer()
                Button { Task { await model.perform(.hold) } } label: { keyed("Hold", "H") }
                    .help("Skip it for this session. Nothing is sent.")
            })
        case .summary:
            AnyView(HStack {
                Spacer()
                Button("Close", action: close).buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
            })
        }
    }

    private var startFooter: some View {
        HStack {
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Spacer()
            if model.saved?.hasUnclear == true {
                Button("Resume") { Task { await model.resume() } }.buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
            } else if model.saved != nil {
                Button("Start a new review") { Task { await model.begin() } }
                Button("Resume") { Task { await model.resume() } }.buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
            } else {
                Button("Start review") { Task { await model.begin() } }.buttonStyle(.accentFilled).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Only choices that can be made are shown. Calendars read through the Mac are answered in Calendar.
    private func cardFooter(_ card: InboxReviewCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if card.replies.isEmpty {
                Text(card.detail.replyNote).font(Theme.Fonts.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            cardButtons(card)
        }
    }

    private func cardButtons(_ card: InboxReviewCardInfo) -> some View {
        HStack(spacing: 8) {
            if card.replies.isEmpty && card.isMacCalendar {
                let opened = model.openedKey == card.entry.id
                Button { Task { await model.perform(.openCalendar) } } label: { keyed("Open in Calendar", "O") }
                    .buttonStyle(.accentFilled)
                    .opacity(opened ? 0.7 : 1)
                    .help("Opens the Calendar app at this day. Nothing is sent from Calopod.")
                Button { Task { await model.perform(.doneInCalendar) } } label: { keyed("Done, next", "D") }
                    .help("Move on once you have answered in Calendar. It is checked again on the next refresh.")
            } else {
                ForEach([ConflictChoice.yes, .maybe, .no], id: \.self) { choice in
                    if card.replies.contains(choice) {
                        Button { Task { await model.perform(.reply(choice)) } } label: {
                            keyed(InboxReviewModel.name(choice), choice == .yes ? "Y" : choice == .no ? "N" : "M")
                        }
                    }
                }
            }
            Spacer()
            Button { Task { await model.perform(.hold) } } label: { keyed("Hold", "H") }
                .help("Skip it for this session. Nothing is sent or marked.")
        }
    }

    private func keyed(_ title: String, _ key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).font(Theme.Fonts.tiny.monospaced()).opacity(0.55)
        }
    }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ReviewSummary: View {
    let progress: InboxReviewProgress?
    let paused: Bool
    var calendarSkips = 0

    var body: some View {
        let totals = progress?.totals
        return VStack(alignment: .leading, spacing: 14) {
            if let totals {
                Text(heading(progress, totals)).font(Theme.Fonts.sectionTitle)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                    count("Replies recorded", totals.recorded, detail: "Yes \(totals.yes) · Maybe \(totals.maybe) · No \(totals.no)")
                    count("Held", totals.held, detail: calendarSkips > 0 ? "\(min(calendarSkips, totals.held)) left for the Calendar app" : nil)
                    count("Outcome unclear", totals.unclear, tint: totals.unclear > 0 ? Theme.caution : nil)
                    if totals.failed + totals.unavailable + totals.changed > 0 {
                        count("Not sent", totals.failed + totals.unavailable + totals.changed)
                    }
                    Divider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                    count("Overlaps resolved", totals.overlapsResolved)
                    count("New overlaps created", totals.overlapsCreated, tint: totals.overlapsCreated > 0 ? Theme.bad : nil)
                    count("Overlaps left", totals.overlapsRemaining)
                }
                .font(Theme.Fonts.body)
                if !totals.overlapsAreComplete {
                    Hint { Text("Some calendars were out of date or only partly read, so the overlap counts may be low.") }
                }
                if progress?.hasUnclear == true {
                    Banner(kind: .caution, text: "A reply has an unclear outcome. It is never sent again. Choose Resume next time to check what happened.")
                } else if totals.queueReviewed {
                    Text(totals.inboxResolved ? "Your inbox is clear." : "Everything in this queue was looked at, but \(totals.remainingInbox) item\(totals.remainingInbox == 1 ? "" : "s") still need\(totals.remainingInbox == 1 ? "s" : "") attention.")
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                } else {
                    Text("Your progress is saved. Choose Review, then Resume, to carry on.")
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
            }
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
            if let detail { Text(detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary) } else { Color.clear.frame(width: 0, height: 0) }
        }
    }
}
