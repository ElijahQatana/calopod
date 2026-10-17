import CalopodCommands
import SwiftUI

/// Hours down the side, one column per day.
struct ScheduleGrid: View {
    let model: CalendarModel
    let colors: CalendarColors

    private static let hourHeight: CGFloat = 52
    private static let gutter: CGFloat = 48
    private static let firstHour = 7
    private static let sidewaysSpace = "sideways"

    /// Narrower days scroll sideways instead of squeezing event titles.
    private static let minimumDayWidth: CGFloat = 96

    var body: some View {
        let days = model.days
        GeometryReader { proxy in
            ScrollViewReader { sideways in
                ScrollView(.horizontal) {
                    grid(days)
                        .frame(
                            width: max(proxy.size.width, Self.gutter + CGFloat(days.count) * Self.minimumDayWidth),
                            height: proxy.size.height)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .coordinateSpace(name: Self.sidewaysSpace)
                .task(id: days) {
                    // Keep today in view when the days do not all fit.
                    try? await Task.sleep(for: .milliseconds(60))
                    if let today = days.first(where: model.isToday) { sideways.scrollTo(today, anchor: .center) }
                }
                .onChange(of: model.selectedID) {
                    // Bring the selected event's day into view when the inspector narrows the grid.
                    guard let event = model.selected else { return }
                    let day = days.first { model.calendar.isDate($0, inSameDayAs: event.startsAt) }
                    if let day { withAnimation { sideways.scrollTo(day, anchor: .center) } }
                }
            }
        }
    }

    private func grid(_ days: [Date]) -> some View {
        VStack(spacing: 0) {
            dayHeaders(days)
            allDayStrip(days)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days, id: \.self) { day in
                            DayColumn(model: model, colors: colors, day: day, hourHeight: Self.hourHeight)
                        }
                    }
                    .frame(height: 24 * Self.hourHeight)
                    .background(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Color.clear.frame(width: 1, height: Self.hourHeight * CGFloat(Self.firstHour))
                            Color.clear.frame(width: 1, height: 1).id("start")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .task {
                    // Wait a beat so the content has been laid out before scrolling.
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.scrollTo("start", anchor: .top)
                }
            }
        }
    }

    private func dayHeaders(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let today = model.isToday(day)
                Button {
                    model.anchor = day
                    model.mode = .day
                } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(Theme.Fonts.label).foregroundStyle(today ? Theme.accent : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(today ? Theme.Fonts.bodySemibold : Theme.Fonts.body)
                            .foregroundStyle(today ? Theme.onAccent : .primary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(today ? Theme.accent : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(day)
                .allowsHitTesting(model.mode == .week)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func allDayStrip(_ days: [Date]) -> some View {
        let perDay = days.map { ScheduleLayout.allDay(model.events, on: $0, calendar: model.calendar) }
        if perDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(Theme.Fonts.tiny).foregroundStyle(.secondary)
                    .frame(width: Self.gutter, alignment: .trailing).padding(.trailing, 6).padding(.top, 3)
                ForEach(perDay.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        ForEach(perDay[index]) { event in
                            Button { model.selectedID = event.id } label: {
                                ScheduleEventBlock(
                                    event: event, color: colors.color(for: event.calendarID).color,
                                    isSelected: model.selectedID == event.id, width: 200, height: 24)
                            }
                            .buttonStyle(.plain)
                            .frame(height: 24)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Stays at the left edge of the visible grid when the days scroll sideways, so the hours are always readable.
    private var hourLabels: some View {
        GeometryReader { proxy in
            let shift = max(0, -proxy.frame(in: .named(Self.sidewaysSpace)).minX)
            ZStack(alignment: .topTrailing) {
                ForEach(1..<24, id: \.self) { hour in
                    Text(Self.label(hour))
                        .font(Theme.Fonts.label.monospacedDigit()).foregroundStyle(.secondary)
                        .offset(y: CGFloat(hour) * Self.hourHeight - 9)
                        .padding(.trailing, 6)
                }
            }
            .frame(width: Self.gutter, height: 24 * Self.hourHeight, alignment: .topTrailing)
            .background { if shift > 0.5 { Theme.contentFill } }
            .offset(x: shift)
        }
        .frame(width: Self.gutter, height: 24 * Self.hourHeight)
        .zIndex(1)
    }

    private static func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct DayColumn: View {
    let model: CalendarModel
    let colors: CalendarColors
    let day: Date
    let hourHeight: CGFloat

    private static let crowdedBlockWidth: CGFloat = 64

    var body: some View {
        let placements = ScheduleLayout.placements(model.events, on: day, calendar: model.calendar)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(1..<24, id: \.self) { hour in
                    Rectangle().fill(.quaternary.opacity(0.7)).frame(height: 1)
                        .offset(y: CGFloat(hour) * hourHeight)
                }
                ForEach(placements) { placement in
                    let slot = (proxy.size.width - 4) / CGFloat(placement.columns)
                    let height = max(CGFloat(placement.height) / 60 * hourHeight - 2, 14)
                    let left = 2 + slot * CGFloat(placement.column)
                    // Crowded columns overlap a little, later ones on top, so each title keeps some room.
                    let width = min(max(slot - 2, Self.crowdedBlockWidth), max(proxy.size.width - left - 2, 8))
                    Button { model.selectedID = placement.event.id } label: {
                        ScheduleEventBlock(
                            event: placement.event, color: colors.color(for: placement.event.calendarID).color,
                            isSelected: model.selectedID == placement.event.id, width: width, height: height)
                    }
                    .buttonStyle(.plain)
                    .frame(width: width, height: height)
                    .offset(x: left, y: CGFloat(placement.top) / 60 * hourHeight + 1)
                        .zIndex(model.selectedID == placement.event.id ? 100 : Double(placement.column))
                }
                if model.isToday(day) { NowLine(hourHeight: hourHeight, calendar: model.calendar) }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
    }
}

private struct NowLine: View {
    let hourHeight: CGFloat
    let calendar: Calendar

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let minutes = now.timeIntervalSince(calendar.startOfDay(for: now)) / 60
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.bad).frame(height: 2)
                Circle().fill(Theme.bad).frame(width: 8, height: 8).offset(x: -4)
            }
            .offset(y: CGFloat(minutes) / 60 * hourHeight - 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
