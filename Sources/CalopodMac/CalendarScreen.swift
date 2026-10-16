import CalopodCommands
import SwiftUI

struct CalendarScreen: View {
    @State private var model = CalendarModel()
    private let colors = CalendarColors.shared

    /// Below this width the inspector floats over the grid instead of taking room from it.
    private static let sideInspectorWidth: CGFloat = 900

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width >= Self.sideInspectorWidth
            VStack(spacing: 0) {
                header
                notices
                HStack(alignment: .top, spacing: 0) {
                    content
                    if side, model.selected != nil { inspector.frame(width: 270).padding([.trailing, .bottom], 12) }
                }
                .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                if !side, model.selected != nil {
                    inspector.frame(width: 270).frame(maxHeight: 420)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                        .padding(12).padding(.top, 96)
                }
            }
        }
        .task {
            // Reads the local copy only, so it shows at once even while a sync is running.
            while !Task.isCancelled {
                await model.reload()
                colors.assignMissing(to: model.calendars.map(\.id))
                try? await Task.sleep(for: .seconds(30))
            }
        }
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
                    colors: colors, close: { model.selectedID = nil })
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(Theme.title(.title2)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                PillPicker(options: [("Day", CalendarModel.Mode.day), ("Week", .week)], selection: $model.mode)
                    .frame(width: 140)
                Button("Today") { model.goToToday() }.buttonStyle(.bordered).controlSize(.large)
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.circleToolbar).accessibilityLabel("Previous")
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.circleToolbar).accessibilityLabel("Next")
            }
            if !model.calendars.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.calendars) { calendar in chip(calendar) }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
    }

    @ViewBuilder
    private var notices: some View {
        let lines = model.notices
        if !lines.isEmpty || model.loadFailed && model.schedule != nil {
            VStack(spacing: 6) {
                ForEach(lines, id: \.self) { Banner(kind: .caution, text: $0) }
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
        return Button { model.toggle(calendar.id) } label: {
            HStack(spacing: 6) {
                Circle().fill(shown ? color : .clear).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                Text(calendar.name).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
            .opacity(shown ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.name)
        .accessibilityValue(shown ? "Shown" : "Hidden")
        .help(shown ? "Hide in this view" : "Show in this view")
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
