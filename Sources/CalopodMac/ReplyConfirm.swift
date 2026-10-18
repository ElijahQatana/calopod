import CalopodCommands
import SwiftUI

/// What the confirm step tells someone before a reply goes out. The review sheet and the Inbox
/// detail pane show the same thing.
@MainActor
struct ReplyConfirmation: Equatable {
    let event: String
    let told: String
    let answer: String
    let sentThrough: String
    let overlaps: [String]
    let warning: String

    /// The account and calendar, with the calendar's local name when there is one.
    static func account(_ account: String, connection: String, calendarID: String, aliases: CalendarAliases = .shared) -> String {
        guard let alias = aliases.alias(for: calendarID) else { return account }
        return "\(connection) / \(alias)"
    }

    init(event: String, told: String, answer: String, sentThrough: String, overlaps: [String], warning: String) {
        self.event = event; self.told = told; self.answer = answer
        self.sentThrough = sentThrough; self.overlaps = overlaps; self.warning = warning
    }

    /// From the detail pane. The provider's own notification wording is only known during a review.
    init(detail: InboxDetail, reply: ConflictChoice, aliases: CalendarAliases = .shared) {
        let entry = detail.entry
        self.init(
            event: entry.title, told: entry.organizer ?? "The organizer", answer: InboxReviewModel.name(reply),
            sentThrough: Self.account(detail.account, connection: detail.connection, calendarID: entry.calendarID, aliases: aliases),
            overlaps: detail.preview(for: reply)?.overlaps ?? [],
            warning: "The organizer and other guests may be notified. This cannot be unsent.")
    }
}

struct ReplyConfirmView: View {
    let confirmation: ReplyConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this reply?").font(Theme.Fonts.sectionTitle)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                fact("Event", confirmation.event)
                fact("Told", confirmation.told)
                fact("Answer", confirmation.answer)
                fact("Sent through", confirmation.sentThrough)
                fact("Overlaps after", confirmation.overlaps.isEmpty ? "None" : confirmation.overlaps.joined(separator: ", "))
            }
            .font(Theme.Fonts.body)
            Banner(kind: .caution, text: confirmation.warning)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
