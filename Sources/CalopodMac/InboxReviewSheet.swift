import CalopodCommands
import CalopodDomain
import SwiftUI

/// Goes through the inbox one event at a time. Everything is keyboard driven.
/// The sheet is sized from the window. A card has its details on the left and the day view on the
/// right, or stacks when the sheet is narrow, so it fits without scrolling on most displays.
struct InboxReviewSheet: View {
    let model: InboxReviewModel
    let colors: CalendarColors
    /// The size of the window the sheet hangs from.
    var window = ReviewSheetLayout.fallbackWindow
    let close: () -> Void
    private let aliases = CalendarAliases.shared

    @FocusState private var focused: Bool
    @State private var showsMore = false

    private static let noticeSeconds = 4.0
    private static let edge: CGFloat = 20

    private var size: CGSize { ReviewSheetLayout.size(in: window) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, Self.edge).padding(.top, 14).padding(.bottom, 10)
            Divider()
            ZStack(alignment: .bottomLeading) {
                mainBody
                if let notice = model.notice, showsNotice {
                    ReviewToast(text: notice, onDismiss: model.dismissNotice)
                        .padding(.bottom, 10).padding(.horizontal, Self.edge)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: model.notice)
            if let footer = footerContent {
                Divider()
                footer.controlSize(.large).padding(.horizontal, Self.edge).padding(.vertical, 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            if !Task.isCancelled { model.dismissNotice() }
        }
        .onKeyPress(phases: .down) { press in
            let text = press.key == .return ? ReviewKeyboard.returnKey : press.key == .escape ? ReviewKeyboard.escapeKey : press.characters
            // Only keys the review uses are taken, so Esc still closes the sheet from a card.
            guard let key = model.interpret(text) else { return .ignored }
            Task { await model.perform(key) }
            return .handled
        }
    }

    @ViewBuilder
    private var mainBody: some View {
        if case .card(let card) = model.phase {
            cardBody(card)
        } else {
            // Not a card: one centered column that scrolls only when it has to.
            ScrollView {
                content.padding(Self.edge)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        case .card: EmptyView() // drawn by `cardBody`
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

    @ViewBuilder
    private func cardBody(_ card: InboxReviewCardInfo) -> some View {
        if ReviewSheetLayout.isSideBySide(width: size.width) {
            HStack(alignment: .top, spacing: 20) {
                ScrollView { details(card, stacked: false).frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollBounceBehavior(.basedOnSize)
                dayView(card)
                    .frame(width: ReviewSheetLayout.dayColumnWidth(body: size.width - 2 * Self.edge))
            }
            .padding(Self.edge)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    details(card, stacked: true)
                    dayView(card).frame(height: ReviewSheetLayout.compactDayHeight + 24)
                }
                .padding(Self.edge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func dayView(_ card: InboxReviewCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Around this time").font(Theme.Fonts.bodySemibold)
            ContextStrip(detail: card.detail, colors: colors, fillsHeight: true)
        }
    }

    private func details(_ card: InboxReviewCardInfo, stacked: Bool) -> some View {
        let entry = card.entry
        let when = entry.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", " + InboxText.time(entry)
        return VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(Theme.Fonts.sectionTitle).lineLimit(stacked ? 2 : 3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(entry.reasons, id: \.self) { StatusPill(text: InboxText.label($0, entry), color: InboxText.tint($0)) }
            }
            if stacked {
                fact("When", when)
                if !card.neighbors.isEmpty { neighbors(card) }
                note(card)
                DisclosureGroup("More details", isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 10) { extras(card, entry) }.padding(.top, 8)
                }
                .font(Theme.Fonts.secondaryMedium)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16, alignment: .topLeading)],
                          alignment: .leading, spacing: 10) {
                    fact("When", when)
                    extras(card, entry)
                }
                if !card.neighbors.isEmpty { neighbors(card) }
                note(card)
            }
        }
    }

    @ViewBuilder
    private func extras(_ card: InboxReviewCardInfo, _ entry: InboxEntry) -> some View {
        if let place = entry.location, !place.isEmpty { fact("Where", place) }
        if let organizer = entry.organizer { fact("Organizer", organizer) }
        fact("Calendar", account(card))
    }

    /// What replying does here. Calendars read through the Mac are answered in the Calendar app.
    @ViewBuilder
    private func note(_ card: InboxReviewCardInfo) -> some View {
        if card.replies.isEmpty {
            Text(card.detail.replyNote).font(Theme.Fonts.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Theme.Fonts.tiny).foregroundStyle(.secondary)
            Text(value).font(Theme.Fonts.label).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        ReplyConfirmView(confirmation: ReplyConfirmation(
            event: card.entry.title, told: card.organizer ?? "The organizer", answer: InboxReviewModel.name(reply),
            sentThrough: account(card), overlaps: card.preview(for: reply)?.overlaps ?? [],
            warning: (card.notification ?? "The organizer may be notified.") + " This cannot be unsent."))
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
    private func cardFooter(_ card: InboxReviewCardInfo) -> some View { cardButtons(card) }

    private func cardButtons(_ card: InboxReviewCardInfo) -> some View {
        HStack(spacing: 8) {
            if let link = card.entry.meeting {
                JoinButton(link: link, prominent: MeetingLink.isNear(startsAt: card.entry.startsAt, endsAt: card.entry.endsAt)) {
                    Task { await model.joinMeeting(link) }
                }
                .help(JoinButton.help(for: link))
            }
            if card.detail.canOpenInCalendar {
                let opened = model.openedKey == card.entry.id
                Button { Task { await model.perform(.openCalendar) } } label: { keyed("Open in Calendar", "O") }
                    .buttonStyle(.accentFilled)
                    .opacity(opened ? 0.7 : 1)
                    .help(CalendarOpenText.help)
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

/// A short notice over the bottom of the body, where the details leave room. It closes itself, so it never takes room from the card.
private struct ReviewToast: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text).font(Theme.Fonts.secondary).lineLimit(1).truncationMode(.tail)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Theme.Fonts.smallIcon).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Theme.pane))
        .background(Capsule().fill(Theme.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Theme.paneLine, lineWidth: 1))
        .shadow(color: Theme.panelShadow, radius: 6, y: 2)
        .help(text)
    }
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
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(totals.lines.enumerated()), id: \.offset) { index, line in
                        if index > 0, totals.lines[index - 1].section != line.section {
                            Divider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                        }
                        row(line)
                    }
                }
                .font(Theme.Fonts.body)
                if !totals.overlapsAreComplete {
                    Hint { Text("Some calendars were out of date or only partly read, so the overlap counts may be low.") }
                }
                if progress?.hasUnclear == true {
                    Banner(kind: .caution, text: "A reply has an unclear outcome. It is never sent again. Choose Resume next time to check what happened.")
                } else if totals.queueReviewed {
                    Text(totals.inboxResolved ? "Your inbox is clear." : "Everything in this queue was looked at, but \(totals.remainingInbox) event\(totals.remainingInbox == 1 ? "" : "s") in your Inbox still need\(totals.remainingInbox == 1 ? "s" : "") attention.")
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

    private func row(_ line: InboxReviewSummaryLine) -> some View {
        let tint: Color? = switch line.emphasis { case .caution: Theme.cautionText; case .bad: Theme.badText; case nil: nil }
        var detail = line.detail
        var help = line.help
        if line.label == "Held", calendarSkips > 0, let value = progress?.totals.held {
            detail = "\(min(calendarSkips, value)) left for the Calendar app"
            help += " Left for the Calendar app: Calopod cannot reply for that calendar, so answer those events there."
        }
        return GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.label).foregroundStyle(.secondary)
                Text(help).font(Theme.Fonts.tiny).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 340, alignment: .leading)
            .gridColumnAlignment(.leading)
            Text("\(line.value)").monospacedDigit().fontWeight(.semibold).foregroundStyle(tint ?? .primary)
            if let detail { Text(detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary) } else { Color.clear.frame(width: 0, height: 0) }
        }
    }
}
