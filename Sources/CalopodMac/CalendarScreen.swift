import CalopodCommands
import SwiftUI

struct CalendarScreen: View {
    /// The same model the menu bar keeps current, so the schedule is read once for both.
    @Environment(CalendarModel.self) private var model
    private let colors = CalendarColors.shared
    @Environment(\.sidebarCollapsed) private var collapsed

    /// Opens Inbox with this event selected.
    var openInbox: (ScheduleEvent) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            notices
            // The inspector always sits beside the grid; a narrow grid scrolls instead of being covered.
            HStack(alignment: .top, spacing: 0) {
                content
                if model.selected != nil { inspector.frame(width: 270).padding([.trailing, .bottom], 12) }
            }
            .frame(maxHeight: .infinity)
        }
        .task {
            // Reads the local copy only, so it shows at once even while a sync is running.
            await model.reload()
            assignColors()
        }
        .onChange(of: model.calendars) { assignColors() }
    }

    private func assignColors() {
        colors.assignMissing(
            to: model.calendars.map {
                CalendarColorSource(id: $0.id, providerColor: $0.providerColor, provider: $0.provider)
            },
            ignoring: model.aliases.ignored)
    }

    @ViewBuilder
    private var content: some View {
        if model.schedule == nil {
            Group {
                if model.loadFailed {
                    ContentUnavailableView("Calendar unavailable", systemImage: "calendar.badge.exclamationmark",
                        description: Text("Calopod could not read its saved calendar data."))
                } else {
                    ProgressView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.calendars.isEmpty {
            ContentUnavailableView("No calendars selected", systemImage: "calendar",
                description: Text("Choose calendars in Calendars and they will appear here."))
        } else {
            ScheduleGrid(model: model, colors: colors).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inspector: some View {
        Group {
            if let event = model.selected {
                EventInspector(
                    event: event, calendar: model.calendars.first { $0.id == event.calendarID },
                    colors: colors, close: { model.selectedID = nil }, openInbox: { openInbox(event) })
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: title, horizontal: Self.headerInset) {
                PillPicker(options: [("Day", CalendarModel.Mode.day), ("Week", .week)], selection: Bindable(model).mode, quiet: true)
                    .fixedSize()
                Button("Today") { model.goToToday() }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.bodyMedium)
                    .padding(.horizontal, 16).frame(height: Self.controlHeight)
                    .background(Capsule().fill(.quaternary))
                    .contentShape(Capsule())
                HStack(spacing: 0) {
                    stepButton("chevron.left", label: "Previous", by: -1)
                    stepButton("chevron.right", label: "Next", by: 1)
                }
                .background(Capsule().fill(.quaternary))
            }
            if !model.calendars.isEmpty {
                // One row: the view mode stays put and the chips scroll, so nothing wraps at narrow widths.
                HStack(spacing: 10) {
                    PillPicker(
                        options: CalendarViewMode.allCases.map { ($0.title, $0) }, selection: Bindable(model).viewMode, quiet: true
                    )
                    .fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.chipCalendars) { calendar in chip(calendar) }
                            copiesChip
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Self.headerInset)
        .padding(.top, Theme.Page.topPadding(collapsed: collapsed, inlineHeader: true))
        .padding(.bottom, 12)
    }

    private static let headerInset: CGFloat = 18

    private static let controlHeight = Theme.Control.height

    private func stepButton(_ symbol: String, label: String, by direction: Int) -> some View {
        Button { model.step(direction) } label: {
            Image(systemName: symbol).font(Theme.Fonts.smallIcon)
                .frame(width: 40, height: Self.controlHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var notices: some View {
        let lines = model.notices
        if !lines.isEmpty || model.openNotice != nil || model.loadFailed && model.schedule != nil {
            VStack(spacing: 6) {
                if let note = model.openNotice { Banner(kind: .info, text: note, lineLimit: 2) }
                ForEach(lines, id: \.self) { Banner(kind: .caution, text: $0, lineLimit: 2) }
                if model.loadFailed && model.schedule != nil {
                    Banner(kind: .caution, text: "Calopod could not refresh this view, so it may be out of date.")
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 8)
        }
    }

    private func chip(_ calendar: ScheduleCalendar) -> some View {
        let shown = !model.hidden.contains(calendar.id)
        let color = colors.color(for: calendar.id).color
        let name = model.aliases.name(for: calendar.id, real: calendar.name)
        return Button { model.toggle(calendar.id) } label: {
            HStack(spacing: 6) {
                Circle().fill(shown ? color : .clear).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                Text(name).font(Theme.Fonts.chip).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(minHeight: Theme.Control.chipHeight)
            .background(Capsule().fill(.quaternary))
            .opacity(shown ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(shown ? "Shown" : "Hidden")
        .help(shown ? "Hide in this view" : "Show in this view")
    }

    private var copiesChip: some View {
        let fixed = model.viewMode != .all
        let shown = model.copiesAreDrawn
        return Button { model.showCopies.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: shown ? "eye" : "eye.slash").font(Theme.Fonts.tiny)
                Text("Calopod copies").font(Theme.Fonts.chip).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(minHeight: Theme.Control.chipHeight)
            .background(Capsule().fill(.quaternary))
            .opacity(shown ? (fixed ? 0.6 : 1) : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(fixed)
        .accessibilityLabel("Calopod copies")
        .accessibilityValue(shown ? "Shown" : "Hidden")
        .help(copiesHelp(shown))
    }

    private func copiesHelp(_ shown: Bool) -> String {
        switch model.viewMode {
        case .all: shown ? "Hide the Busy copies Calopod made" : "Show the Busy copies Calopod made"
        case .sources: "Sources shows only the original events, never Calopod's copies."
        case .destinations: "Destinations always shows the copies Calopod made, since they are what it is for."
        }
    }

    private var title: String {
        let days = model.days
        guard let first = days.first, let last = days.last else { return "" }
        if model.mode == .day { return first.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
        if model.calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return first.formatted(.dateTime.month(.wide).year())
        }
        return "\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated).year()))"
    }
}

/// Lays chips out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
