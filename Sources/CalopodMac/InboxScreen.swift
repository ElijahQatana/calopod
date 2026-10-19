import CalopodCommands
import CalopodSync
import SwiftUI

struct InboxScreen: View {
    let model: InboxModel
    let navigation: AppNavigation
    let colors: CalendarColors
    @State private var showingReview = false

    private var filter: InboxFilter { navigation.inboxFilter }
    private var entries: [InboxEntry] { model.board?.entries(for: filter) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let notice = model.notice { Banner(kind: model.noticeIsHint ? .info : .error, text: notice, onDismiss: model.dismissNotice) }
            if let board = model.board, !board.isComplete { staleBanner(board) }
            if let board = model.board {
                filters(board)
                if board.entries.isEmpty { allAnswered(board) } else { split }
            } else {
                Spacer()
            }
        }
        .pageEdges(inlineHeader: true)
        .task {
            await model.reload()
            settleSelection()
        }
        .onDisappear { model.dismissNotice() }
        .onChange(of: filter) { settleSelection() }
        .onChange(of: model.board) { settleSelection() }
        .sheet(isPresented: $showingReview, onDismiss: { Task { await model.reload() } }) {
            InboxReviewSheet(model: model.review, colors: colors) { showingReview = false }
                .appTypography()
        }
    }

    /// Selects the event another screen asked for, or keeps a valid row selected.
    private func settleSelection() {
        if model.board != nil, let id = navigation.takeInboxEvent(in: entries) { model.selection = id }
        model.ensureSelection(in: entries)
    }

    // MARK: Header and filters

    private var header: some View {
        PageHeader(title: "Inbox") {
            BusyLine(text: model.busy)
            Button("Review") {
                model.review.open(filter: filter)
                showingReview = true
            }
            .buttonStyle(.accentFilled)
            .disabled(model.isBusy)
            .help("Go through your inbox one event at a time")
            RefreshButton(busy: model.isBusy, help: "Refresh. Re-reads your calendars and changes nothing.") {
                Task { await model.refresh() }
            }
        }
    }

    private func staleBanner(_ board: InboxBoard) -> some View {
        Banner(kind: .caution, text: board.staleText(suffix: "so overlaps may be missing."))
    }

    private func filters(_ board: InboxBoard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(InboxFilter.allCases) { option in
                    let selected = option == filter
                    Button { navigation.inboxFilter = option } label: {
                        HStack(spacing: 6) {
                            Text(option.title)
                            Text("\(board.count(option))").monospacedDigit()
                                .foregroundStyle(selected ? Theme.onAccent.opacity(0.8) : .secondary)
                        }
                        .font(Theme.Fonts.chip)
                        .foregroundStyle(selected ? Theme.onAccent : .primary)
                        .padding(.horizontal, 14).frame(height: Theme.Control.chipHeight)
                        .background(Capsule().fill(selected ? Theme.accent : Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func allAnswered(_ board: InboxBoard) -> some View {
        ContentUnavailableView {
            Label("All answered", systemImage: "checkmark.circle")
        } description: {
            if let checked = board.lastChecked {
                Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened)).")
            } else {
                Text("Calopod has not read your calendars yet.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List and detail

    private var split: some View {
        HStack(alignment: .top, spacing: 20) {
            list.frame(width: 300)
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "tray",
                                   description: Text("No events match this filter."))
        } else {
            InboxList(
                entries: entries, colors: colors,
                selection: Binding(get: { model.selection }, set: { model.selection = $0 }))
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let detail = model.detail, detail.entry.id == model.selection {
            ScrollView { InboxDetailView(model: model, detail: detail, colors: colors, entries: entries) }
        } else {
            ContentUnavailableView("Pick an event", systemImage: "tray",
                                   description: Text("Choose something from the list to see it here."))
        }
    }
}

enum InboxText {
    static func time(_ entry: InboxEntry) -> String {
        if entry.isAllDay { return "All day" }
        return "\(entry.startsAt.formatted(date: .omitted, time: .shortened)) to \(entry.endsAt.formatted(date: .omitted, time: .shortened))"
    }

    static func label(_ reason: InboxAttentionReason, _ entry: InboxEntry) -> String {
        switch reason {
        case .needsResponse: "Needs RSVP"
        case .maybe: "Maybe"
        case .changedAfterResponse: entry.changeIsUncertain ? "May have changed" : "Changed"
        case .conflict: entry.overlapCount == 1 ? "1 overlap" : "\(entry.overlapCount) overlaps"
        }
    }

    /// The row's second line: each reason in its own color, so only an overlap reads as a warning.
    static func statusLine(_ entry: InboxEntry) -> Text {
        entry.reasons.enumerated().reduce(Text("")) { line, item in
            let part = Text(label(item.element, entry)).foregroundColor(textTint(item.element))
            return item.offset == 0 ? part : line + Text(" · ").foregroundColor(.secondary) + part
        }
    }

    /// Like `tint`, but dark enough to read as text.
    static func textTint(_ reason: InboxAttentionReason) -> Color {
        switch reason {
        case .needsResponse: Theme.accent
        case .conflict: Theme.badText
        case .maybe, .changedAfterResponse: Theme.cautionText
        }
    }

    static func tint(_ reason: InboxAttentionReason) -> Color {
        switch reason {
        case .needsResponse: Theme.accent
        case .conflict: Theme.bad
        case .maybe, .changedAfterResponse: Theme.caution
        }
    }
}
