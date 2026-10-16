import CalopodCommands
import SwiftUI

/// Hours down the side, one column per day.
struct ScheduleGrid: View {
    let model: CalendarModel
    let colors: CalendarColors

    private static let hourHeight: CGFloat = 52
    private static let gutter: CGFloat = 48
    private static let firstHour = 7

    var body: some View {
        let days = model.days
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
                    .overlay(alignment: .topLeading) {
                        Color.clear.frame(width: 1, height: 1)
                            .offset(y: Self.hourHeight * CGFloat(Self.firstHour))
                            .id("start")
                    }
                }
                .onAppear { proxy.scrollTo("start", anchor: .top) }
            }
        }
    }

    private func dayHeaders(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                let today = model.isToday(day)
                Button {
                    model.anchor = day
                    model.mode = .day
                } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption).foregroundStyle(today ? Theme.accent : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 16, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? Theme.onAccent : .primary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(today ? Theme.accent : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.mode == .day)
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
                Text("all-day").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: Self.gutter, alignment: .trailing).padding(.trailing, 6).padding(.top, 3)
                ForEach(perDay.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        ForEach(perDay[index]) { event in
                            ScheduleEventBlock(
                                event: event, color: colors.color(for: event.calendarID).color,
                                isSelected: model.selectedID == event.id, height: 20)
                                .frame(height: 20)
                                .onTapGesture { model.selectedID = event.id }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var hourLabels: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(1..<24, id: \.self) { hour in
                Text(Self.label(hour))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                    .offset(y: CGFloat(hour) * Self.hourHeight - 7)
                    .padding(.trailing, 6)
            }
        }
        .frame(width: Self.gutter, height: 24 * Self.hourHeight, alignment: .topTrailing)
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
                    ScheduleEventBlock(
                        event: placement.event, color: colors.color(for: placement.event.calendarID).color,
                        isSelected: model.selectedID == placement.event.id, height: height)
                        .frame(width: max(slot - 2, 8), height: height)
                        .offset(x: 2 + slot * CGFloat(placement.column), y: CGFloat(placement.top) / 60 * hourHeight + 1)
                        .onTapGesture { model.selectedID = placement.event.id }
                        .zIndex(model.selectedID == placement.event.id ? 1 : 0)
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
