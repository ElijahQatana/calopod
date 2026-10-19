import CalopodCommands
import SwiftUI

/// Layout for the small day view around an Inbox event.
enum DayStripLayout {
    /// Points per minute: 90 per hour.
    static let pointsPerMinute: CGFloat = 1.5
    static let minimumHeight: CGFloat = 260
    static let maximumHeight: CGFloat = 340

    struct Block: Equatable, Identifiable {
        var id: String { entry.id }
        let entry: InboxContextEntry
        let column: Int
        let columns: Int
        /// Minutes below the top of the window.
        let top: Double
        let height: Double
    }

    /// Side by side columns come from the Calendar screen's own layout, so both agree. Times are
    /// moved so the top of the window is midnight, which keeps a window across midnight whole.
    static func blocks(_ entries: [InboxContextEntry], windowStart: Date) -> [Block] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let origin = Date(timeIntervalSince1970: 86_400 * 100)
        let shift = origin.timeIntervalSince(windowStart)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let events = entries.map {
            ScheduleEvent(id: $0.id, calendarID: $0.calendarID, title: $0.title,
                          startsAt: $0.startsAt.addingTimeInterval(shift), endsAt: $0.endsAt.addingTimeInterval(shift))
        }
        return ScheduleLayout.placements(events, on: origin, calendar: utc).compactMap { placement in
            byID[placement.event.id].map {
                Block(entry: $0, column: placement.column, columns: placement.columns, top: placement.top, height: placement.height)
            }
        }
    }

    /// Whole hours inside the window, as minutes below its top.
    static func hourMarks(from start: Date, to end: Date, calendar: Calendar = .current) -> [(date: Date, minutes: Double)] {
        var marks: [(Date, Double)] = []
        var next = calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0),
                                     matchingPolicy: .nextTime) ?? end
        while next < end {
            marks.append((next, next.timeIntervalSince(start) / 60))
            next.addTimeInterval(3600)
        }
        return marks
    }

    /// Room above the first hour and below the last, so no label is cut off.
    static let inset: CGFloat = 10

    static func height(forMinutes minutes: Double, inset: CGFloat = 0) -> CGFloat {
        min(max(CGFloat(minutes) * pointsPerMinute + 2 * inset, minimumHeight), maximumHeight)
    }

    /// The most room an hour gets when the view fills a tall space, and the least before it scrolls.
    static let maximumPointsPerHour: CGFloat = 120
    static let minimumPointsPerHour: CGFloat = 44

    /// Spreads whole hours over the room there is. It only drops below the minimum, and so scrolls,
    /// when the hours cannot fit at that size.
    static func pointsPerHour(hours: Double, available: CGFloat, inset: CGFloat = DayStripLayout.inset) -> CGFloat {
        let fit = ((available - 2 * inset) / CGFloat(max(hours, 1))).rounded(.down)
        return min(max(fit, minimumPointsPerHour), maximumPointsPerHour)
    }

    /// The window moved out to whole hours, so every hour line inside it has a label.
    static func axis(start: Date, end: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let from = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let to = calendar.dateInterval(of: .hour, for: end.addingTimeInterval(-1))?.end ?? end
        return (from, max(to, from.addingTimeInterval(3600)))
    }
}

/// The event and its neighbors as a small day view: time down the left, side by side columns for
/// overlaps. The selected event has the accent outline and what overlaps it the status ring.
struct ContextStrip: View {
    let detail: InboxDetail
    let colors: CalendarColors
    private let aliases = CalendarAliases.shared
    /// Fills the height it is given, spreading the hours over it, instead of a fixed height.
    var fillsHeight = false
    private static let axisWidth: CGFloat = 52

    var body: some View {
        let axis = DayStripLayout.axis(start: detail.windowStart, end: detail.windowEnd)
        let minutes = max(axis.end.timeIntervalSince(axis.start) / 60, 60)
        let blocks = DayStripLayout.blocks(detail.context, windowStart: axis.start)
        let marks = DayStripLayout.hourMarks(from: axis.start, to: axis.end)
        let inset = DayStripLayout.inset
        GeometryReader { proxy in
            let perMinute = fillsHeight
                ? DayStripLayout.pointsPerHour(hours: minutes / 60, available: proxy.size.height) / 60
                : DayStripLayout.pointsPerMinute
            let total = CGFloat(minutes) * perMinute
            ScrollViewReader { scroller in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        ForEach(marks, id: \.date) { mark in
                            HStack(spacing: 6) {
                                Text(mark.date.formatted(date: .omitted, time: .shortened))
                                    .font(Theme.Fonts.tiny).foregroundStyle(.secondary)
                                    .frame(width: Self.axisWidth - 6, alignment: .trailing)
                                Rectangle().fill(.quaternary).frame(height: 0.5)
                            }
                            .offset(y: inset + CGFloat(mark.minutes) * perMinute - 8)
                            .accessibilityHidden(true)
                        }
                        ForEach(blocks) { placed in
                            let area = max(proxy.size.width - Self.axisWidth - 8, 60)
                            let width = area / CGFloat(placed.columns)
                            block(placed.entry)
                                .frame(width: max(width - 3, 24), height: max(CGFloat(placed.height) * perMinute - 2, 18))
                                .padding(.leading, Self.axisWidth + CGFloat(placed.column) * width)
                                .padding(.top, inset + CGFloat(placed.top) * perMinute)
                                .id(placed.id)
                        }
                    }
                    .frame(width: proxy.size.width, height: total + 2 * inset, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    if let focused = detail.context.first(where: \.isFocused) { scroller.scrollTo(focused.id, anchor: .center) }
                }
            }
        }
        .frame(height: fillsHeight ? nil : DayStripLayout.height(forMinutes: minutes, inset: inset))
        .frame(maxHeight: fillsHeight ? .infinity : nil)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .cardSurface()
    }

    private func block(_ item: InboxContextEntry) -> some View {
        let color = colors.color(for: item.calendarID).color
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let ring = item.isFocused ? Theme.accent : item.overlapsFocused ? Theme.bad : color.opacity(0.5)
        let name = aliases.name(for: item.calendarID, real: item.calendarName)
        let when = item.startsAt.formatted(date: .omitted, time: .shortened) + " to " + item.endsAt.formatted(date: .omitted, time: .shortened)
        return Text(item.title)
            .font(item.isFocused ? Theme.Fonts.tinySemibold : Theme.Fonts.tinyMedium)
            .lineLimit(2).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(color.opacity(item.isFocused ? 0.4 : 0.2)).declinedHatch(EventBlockStyle.of(isCopy: false, copyMode: nil, response: ScheduleResponse(item.response)).hatched, color: color))
            .overlay(shape.strokeBorder(ring, lineWidth: item.isFocused || item.overlapsFocused ? 2 : 1))
            .clipShape(shape)
            .help("\(item.title), \(when), \(name)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.title), \(when), \(name)" + (item.overlapsFocused ? ", overlaps this event" : item.isFocused ? ", this event" : ""))
    }
}
