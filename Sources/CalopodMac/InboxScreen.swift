import CalopodCommands
import SwiftUI

struct InboxScreen: View {
    let model: InboxModel
    let navigation: AppNavigation
    let colors: CalendarColors

    private var filter: InboxFilter { navigation.inboxFilter }
    private var entries: [InboxEntry] { model.board?.entries(for: filter) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let notice = model.notice { Banner(kind: .error, text: notice) }
            if let board = model.board, !board.isComplete { staleBanner(board) }
            if let board = model.board {
                filters(board)
                if board.entries.isEmpty { allAnswered(board) } else { split }
            } else {
                Spacer()
            }
        }
        .padding(Theme.pagePadding)
        .task { await model.reload() }
        .onChange(of: filter) { model.ensureSelection(in: entries) }
        .onChange(of: model.board) { model.ensureSelection(in: entries) }
    }

    // MARK: Header and filters

    private var header: some View {
        HStack(spacing: 10) {
            Text("Inbox").font(Theme.title())
            BusyLine(text: model.busy)
            Spacer()
            Button("Choose replies for overlaps") { navigation.selection = .conflicts }
                .help("Open the guided list of overlapping events")
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .buttonStyle(.circleToolbar)
                .disabled(model.isBusy)
                .help("Re-read your calendars. Nothing is changed.")
        }
    }

    private func staleBanner(_ board: InboxBoard) -> some View {
        let names = board.incompleteCalendars
        let which = names.isEmpty ? "Some calendars are" : names.joined(separator: ", ") + (names.count == 1 ? " is" : " are")
        return Banner(kind: .caution, text: "\(which) out of date or only partly read, so overlaps may be missing.")
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
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Theme.onAccent : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
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
        HStack(alignment: .top, spacing: 18) {
            list.frame(width: 270)
            Divider()
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "tray",
                                   description: Text("No events match this filter."))
        } else {
            let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.startsAt) }
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                ForEach(days.keys.sorted(), id: \.self) { day in
                    Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(days[day] ?? []) { row($0).tag($0.id as String?) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ entry: InboxEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(colors.color(for: entry.calendarID).color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(InboxText.time(entry)).font(.caption).foregroundStyle(.secondary)
                Text(InboxText.reasons(entry).joined(separator: " · "))
                    .font(.caption2.weight(.medium)).foregroundStyle(InboxText.tint(entry))
            }
        }
        .padding(.vertical, 2)
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

    static func reasons(_ entry: InboxEntry) -> [String] {
        entry.reasons.map {
            switch $0 {
            case .needsResponse: "Needs RSVP"
            case .maybe: "Maybe"
            case .changedAfterResponse: entry.changeIsUncertain ? "May have changed" : "Changed"
            case .conflict: entry.overlapCount == 1 ? "1 overlap" : "\(entry.overlapCount) overlaps"
            }
        }
    }

    static func tint(_ entry: InboxEntry) -> Color {
        entry.reasons.contains(.conflict) ? Theme.bad : entry.reasons.contains(.needsResponse) ? Theme.accent : Theme.caution
    }
}
