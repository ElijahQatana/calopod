import CalopodCommands
import SwiftUI

/// Details for the selected event. The reply buttons only show what the provider allows;
/// sending is done from Inbox.
struct EventInspector: View {
    let event: ScheduleEvent
    let calendar: ScheduleCalendar?
    let colors: CalendarColors
    private let aliases = CalendarAliases.shared
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    status
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Close details")
                }
                Text(event.title).font(Theme.title(.title3)).fixedSize(horizontal: false, vertical: true)
                details
                if ScheduleLayout.showsOverlap(event) {
                    Banner(kind: .error, text: "Overlaps \(list(event.overlaps)).")
                } else if !event.isCopy {
                    Banner(kind: .info, text: "Nothing overlaps this event.")
                }
                replies
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelFill(.inner, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        if event.isCopy {
            StatusPill(text: "Busy copy", color: .secondary)
        } else {
            switch event.response {
            case .needsResponse: StatusPill(text: "Needs RSVP", color: Theme.caution)
            case .accepted: StatusPill(text: "Accepted", color: Theme.good)
            case .tentative: StatusPill(text: "Maybe", color: Theme.caution)
            case .declined: StatusPill(text: "Declined", color: .secondary)
            case .organizer: StatusPill(text: "You organize", color: Theme.accent)
            case .none: EmptyView()
            }
        }
    }

    private var details: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
            row("When") { Text(when) }
            row("Calendar") {
                HStack(spacing: 6) {
                    Circle().fill(colors.color(for: event.calendarID).color).frame(width: 9, height: 9)
                    Text([calendar.map { aliases.name(for: $0.id, real: $0.name) }, calendar?.account].compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let organizer = event.organizer { row("Organizer") { Text(organizer) } }
            if let location = event.location { row("Where") { Text(location) } }
            if !event.copiedTo.isEmpty {
                row("Copied to") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(event.copiedTo.indices, id: \.self) { index in
                            let copy = event.copiedTo[index]
                            Text("\(aliases.name(for: copy.calendarID, real: copy.calendarName)) · \(copy.fullDetails ? "full details" : "busy only")")
                        }
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var replies: some View {
        if event.isCopy {
            Hint { Text("This is a copy Calopod made, so there is nothing to reply to.") }
        } else if event.replies.isEmpty {
            if let reason = event.replyUnavailableReason { Hint { Text(reason) } }
        } else {
            HStack(spacing: 6) {
                ForEach([ConflictChoice.yes, .maybe, .no], id: \.self) { choice in
                    if event.replies.contains(choice) {
                        Button(label(choice)) {}.frame(maxWidth: .infinity)
                    }
                }
            }
            .controlSize(.large)
            .disabled(true)
            Hint { Text("Replies are sent from Inbox.").font(.caption) }
        }
    }

    private func label(_ choice: ConflictChoice) -> String {
        switch choice {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        case .noChange: "Hold"
        }
    }

    private func row<Value: View>(_ title: String, @ViewBuilder _ value: () -> Value) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            value().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var when: String {
        if event.isAllDay {
            return event.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", all day"
        }
        let day = event.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day())
        let start = event.startsAt.formatted(date: .omitted, time: .shortened)
        let end = event.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(day)\n\(start) to \(end)"
    }

    private func list(_ titles: [String]) -> String {
        let shown = titles.prefix(2).joined(separator: " and ")
        return titles.count > 2 ? "\(shown) and \(titles.count - 2) more" : shown
    }
}
