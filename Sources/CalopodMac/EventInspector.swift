import CalopodCommands
import SwiftUI

/// Details for the selected event. Replies are made from Inbox, so this only points there.
struct EventInspector: View {
    let event: ScheduleEvent
    let calendar: ScheduleCalendar?
    let colors: CalendarColors
    private let aliases = CalendarAliases.shared
    let close: () -> Void
    var openInbox: () -> Void = {}

    var body: some View {
        ScrollView { content }
            .frame(maxHeight: .infinity, alignment: .top)
            .panelFill(.inner, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                status
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.bare).foregroundStyle(.secondary)
                    .accessibilityLabel("Close details")
            }
            lead
            if hasPeopleAndPlace { peopleAndPlace }
            if !event.copiedTo.isEmpty { copies }
            notes
            replies
        }
        .padding(18)
    }

    private var lead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title).font(Theme.Fonts.sectionTitle).fixedSize(horizontal: false, vertical: true)
            Text(when).font(Theme.Fonts.body).foregroundStyle(.secondary)
        }
    }

    private var hasPeopleAndPlace: Bool { calendar != nil || event.organizer != nil || event.location != nil }

    private var peopleAndPlace: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let calendar {
                field("Calendar") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(colors.color(for: event.calendarID).color).frame(width: 9, height: 9)
                        Text(aliases.name(for: calendar.id, real: calendar.name))
                    }
                    Text(calendar.account).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
            }
            if let organizer = event.organizer { field("Organizer") { Text(organizer) } }
            if let location = event.location { field("Where") { Text(location) } }
        }
    }

    private var copies: some View {
        field("Copied to") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(event.copiedTo.indices, id: \.self) { index in
                    let copy = event.copiedTo[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(aliases.name(for: copy.calendarID, real: copy.calendarName))
                        Text(copy.fullDetails ? "Full details" : "Busy only")
                            .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let text = ScheduleLayout.changeText(event) {
            VStack(alignment: .leading, spacing: 8) {
                Banner(kind: .caution, text: "\(text). Review it in Inbox.")
                Button("Open in Inbox", action: openInbox)
            }
        }
        if ScheduleLayout.showsOverlap(event) {
            Banner(kind: .error, text: "Overlaps \(list(event.overlaps)).")
        } else if !event.isCopy && !event.copyOverlaps.isEmpty {
            Banner(kind: .info, text: "Overlaps only a Calopod copy: \(list(event.copyOverlaps)).")
        } else if !event.isCopy {
            Banner(kind: .info, text: "Nothing overlaps this event.")
        }
    }

    /// A small label with its value underneath, so long values get the full width.
    private func field<Value: View>(_ title: String, @ViewBuilder _ value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Fonts.secondaryMedium).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) { value() }
                .font(Theme.Fonts.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    @ViewBuilder
    private var replies: some View {
        if event.isCopy {
            Hint { Text("This is a copy Calopod made, so there is nothing to reply to.") }
        } else if event.replies.isEmpty {
            if let reason = event.replyUnavailableReason { Hint { Text(reason) } }
        } else {
            Hint { Text("Replies are sent from Inbox.").font(Theme.Fonts.secondary) }
            Button("Open in Inbox", action: openInbox)
        }
    }

    private var when: String {
        if event.isAllDay {
            return event.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day()) + ", all day"
        }
        let day = event.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day())
        let start = event.startsAt.formatted(date: .omitted, time: .shortened)
        let end = event.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(day), \(start) to \(end)"
    }

    private func list(_ titles: [String]) -> String {
        let shown = titles.prefix(2).joined(separator: " and ")
        return titles.count > 2 ? "\(shown) and \(titles.count - 2) more" : shown
    }
}
