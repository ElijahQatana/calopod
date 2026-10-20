import CalopodSnapshot
import SwiftUI

struct InboxTab: View {
    var context: SnapshotContext
    @Binding var filter: InboxFilter
    @Binding var openID: String?

    var body: some View {
        let inbox = context.snapshot.inbox
        if let item = inbox.first(where: { $0.id == openID }) {
            EventDetailScreen(item: item, context: context, back: BackAction(label: "Inbox") { openID = nil })
        } else {
            list(inbox)
        }
    }

    private func list(_ inbox: [InboxItem]) -> some View {
        let shown = filter.apply(to: inbox)
        return Screen(title: "Inbox", subtitle: "\(inbox.count) \(inbox.count == 1 ? "item" : "items") · \(context.fromMac)") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                FilterChips(selection: $filter, inbox: inbox)
                if shown.isEmpty {
                    Card {
                        Text(inbox.isEmpty ? "Nothing needs a look." : "Nothing under \(filter.title).")
                            .font(Theme.Fonts.body).padding(16)
                    }
                }
                ForEach(groupedByDay(shown), id: \.day) { group in
                    SectionLabel(text: group.day.formatted(dayFormat))
                    Card {
                        ForEach(group.items, id: \.id) { item in
                            Button { openID = item.id } label: {
                                InboxRow(item: item, calendar: context.snapshot.calendar(for: item.calendarID))
                            }
                            .buttonStyle(.plain)
                            if item.id != group.items.last?.id { Divider().overlay(Theme.line) }
                        }
                    }
                    .shadow(color: Theme.text.opacity(0.06), radius: 6, y: 2)
                }
                ReadOnlyFoot()
            }
            .opacity(context.isStale ? 0.6 : 1)
        }
    }
}

private struct FilterChips: View {
    @Binding var selection: InboxFilter
    var inbox: [InboxItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases, id: \.self) { filter in
                    let on = filter == selection
                    Button { selection = filter } label: {
                        HStack(spacing: 6) {
                            Text(filter.title)
                            Text("\(filter.apply(to: inbox).count)").opacity(0.7)
                        }
                        .font(Theme.Fonts.caption)
                        .padding(.horizontal, 12).frame(height: 34)
                        .foregroundStyle(on ? Theme.onAccent : Theme.text)
                        .background(on ? Theme.accent : Theme.card, in: Capsule())
                        .shadow(color: Theme.text.opacity(on ? 0 : 0.06), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
        }
    }
}

private struct InboxRow: View {
    var item: InboxItem
    var calendar: CalendarEntry?
    @ScaledMetric(relativeTo: .subheadline) private var tileWidth: CGFloat = 84

    var body: some View {
        let color = Theme.calendarColor(calendar)
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(item.isAllDay ? "All day" : item.startsAt.formatted(timeFormat)).font(Theme.Fonts.bodyStrong).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !item.isAllDay { Text(duration).font(.caption2).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(width: min(tileWidth, 96))
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "Untitled").font(Theme.Fonts.bodyStrong).lineLimit(1)
                Text(sourceLine).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary).lineLimit(1)
                ReasonChips(item: item)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var sourceLine: String {
        [calendar?.name, item.sourceName].compactMap { $0 }.joined(separator: " · ")
    }

    private var duration: String { DurationText.short(item.endsAt.timeIntervalSince(item.startsAt)) }
}

struct ReasonChips: View {
    var item: InboxItem

    var body: some View {
        HStack(spacing: 5) {
            ForEach(item.reasons, id: \.self) { reason in
                switch reason {
                case .needsRSVP: Pill(text: "Needs RSVP", color: Theme.accent, fill: Theme.accentSoft)
                case .maybe: Pill(text: "Maybe", color: Theme.caution, fill: Theme.cautionSoft)
                case .unreadChange: Pill(text: "Changed", color: Theme.text, fill: Theme.fill)
                case .conflict: Pill(text: "Conflict", color: Theme.bad, fill: Theme.badSoft)
                }
            }
            if item.changeOrderUncertain { Pill(text: "Order uncertain", color: Theme.secondary, fill: Theme.fill) }
        }
    }
}

private struct Pill: View {
    var text: String
    var color: Color
    var fill: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.leading, 8).padding(.trailing, 9).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(fill, in: Capsule())
    }
}
