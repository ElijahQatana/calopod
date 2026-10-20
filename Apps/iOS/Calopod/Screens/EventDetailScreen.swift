import CalopodSnapshot
import SwiftUI

/// One Inbox item with where it came from. It only shows things; the answer is given on the Mac.
struct EventDetailScreen: View {
    var item: InboxItem
    var context: SnapshotContext
    /// What to call an event that came without a title.
    var untitled = "Untitled"
    var back: BackAction

    var body: some View {
        let detail = EventDetail(item: item, untitled: untitled)
        let calendar = context.snapshot.calendar(for: item.calendarID)
        Screen(title: detail.title, subtitle: whenText, back: back) {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                ReasonChips(item: item).padding(.horizontal, 4)
                if let join = context.snapshot.joinLink(forEvent: item.id) { JoinButton(url: join) }
                SectionLabel(text: "Details")
                Card {
                    Rows(rows: [
                        ("Where", detail.location), ("Organizer", detail.organizer),
                        ("Your response", detail.response), ("Guests", detail.guests),
                    ])
                }
                .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
                SectionLabel(text: "Source")
                Card {
                    HStack {
                        Text("Calendar").foregroundStyle(Theme.secondary)
                        Spacer()
                        Label { Text(calendar?.name ?? "Unknown") } icon: {
                            Circle().fill(Theme.calendarColor(calendar)).frame(width: 9, height: 9)
                        }
                        .fontWeight(.semibold)
                    }
                    .font(Theme.Fonts.body).padding(14)
                    Rows(rows: [("Account", detail.source)])
                }
                .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
                if !item.conflicts.isEmpty {
                    SectionLabel(text: "Overlaps")
                    Card {
                        ForEach(Array(item.conflicts.enumerated()), id: \.offset) { index, other in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.title ?? "Busy").font(Theme.Fonts.bodyStrong)
                                Text(range(other.startsAt, other.endsAt)).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            if index < item.conflicts.count - 1 { Divider().overlay(Theme.line) }
                        }
                    }
                    .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
                }
                if let notes = detail.notes {
                    SectionLabel(text: "Notes")
                    Card { Text(notes).font(Theme.Fonts.body).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                        .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
                }
                if let link = detail.link {
                    Card {
                        Link(destination: link) {
                            Label("Open link", systemImage: "arrow.up.right.square")
                                .font(Theme.Fonts.bodyStrong).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                ReadOnlyFoot(text: "To answer, open Calopod on your Mac.")
            }
            .opacity(context.isStale ? 0.6 : 1)
        }
    }

    private var whenText: String {
        if item.isAllDay { return "\(item.startsAt.formatted(dayFormat)) · All day" }
        return "\(item.startsAt.formatted(dayFormat)) · \(range(item.startsAt, item.endsAt))"
    }

    private func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(timeFormat)) to \(end.formatted(timeFormat))"
    }
}

/// Label and value lines, leaving out any with no value.
private struct Rows: View {
    var rows: [(String, String?)]

    var body: some View {
        let shown = rows.compactMap { label, value in value.map { (label, $0) } }
        ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
            HStack(alignment: .top) {
                Text(row.0).foregroundStyle(Theme.secondary)
                Spacer(minLength: 16)
                Text(row.1).fontWeight(.semibold).multilineTextAlignment(.trailing)
            }
            .font(Theme.Fonts.body).padding(14)
            .accessibilityElement(children: .combine)
            if index < shown.count - 1 { Divider().overlay(Theme.line) }
        }
    }
}

struct JoinButton: View {
    var url: URL

    var body: some View {
        Link(destination: url) {
            Label("Join", systemImage: "video.fill")
                .font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The small Join on a row.
struct JoinPill: View {
    var url: URL

    var body: some View {
        Link(destination: url) {
            Text("Join").font(.caption2.weight(.semibold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.accent, in: Capsule())
        }
        .fixedSize()
    }
}
