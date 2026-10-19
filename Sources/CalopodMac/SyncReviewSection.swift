import CalopodCommands
import SwiftUI

/// The list shown before a sync is applied. Removals come first so they are not missed.
struct SyncReviewSection: View {
    let model: ServiceModel
    let preview: SyncPreview
    @Environment(CalendarModel.self) private var schedule
    @Environment(CalendarAccessModel.self) private var access

    private static let collapsedCount = 8

    @State private var showingAll = false
    @State private var showingUnchecked = false
    @State private var openLineID: String?

    var body: some View {
        let lines = Self.ordered(preview.lines.filter { !$0.isUnchecked })
        let unchecked = preview.lines.filter(\.isUnchecked)
        CardSection("Review before syncing: \(Self.summaryLine(preview))") {
            if !unchecked.isEmpty { uncheckedBlock(unchecked) }
            ForEach(showingAll ? lines : Array(lines.prefix(Self.collapsedCount))) { line in
                CardRow { row(line) }
            }
            if lines.count > Self.collapsedCount {
                CardRow {
                    Button(showingAll ? "Show fewer" : "Show all \(lines.count)") { showingAll.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
            if preview.removals > 0 {
                CardRow {
                    Banner(kind: .caution, text: "\(Self.count(preview.removals, "copy", "copies")) Calopod made earlier will be deleted from the target calendar.")
                }
            }
            ForEach(preview.warnings, id: \.self) { warning in
                CardRow { Banner(kind: .caution, text: warning) }
            }
            CardRow {
                HStack {
                    Button("Cancel") { model.discardPreview() }
                    Spacer()
                    Button("Apply") { Task { await model.applyPreview() } }
                        .buttonStyle(.accentFilled)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!preview.canApply)
                }
                .disabled(model.isBusy)
            }
        }
    }

    /// One explanation instead of a list of repairs: nothing was read, so nothing is known.
    @ViewBuilder
    private func uncheckedBlock(_ unchecked: [SyncPreview.Line]) -> some View {
        CardRow {
            VStack(alignment: .leading, spacing: 12) {
                Banner(kind: .caution, text: Self.uncheckedExplanation)
                if model.calendarAccess.isMissing {
                    CalendarAccessCard(access: access, state: model.calendarAccess)
                } else {
                    HStack {
                        RefreshCalendarsButton()
                        Button("Try again") { Task { await model.previewSync() } }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        CardRow {
            DisclosureGroup("Could not be checked (\(unchecked.count))", isExpanded: $showingUnchecked) {
                ForEach(unchecked) { line in row(line).padding(.top, 8) }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: SyncPreview.Line) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            StatusPill(text: Self.label(line), color: Self.color(line))
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title ?? "Copy made earlier").lineLimit(1)
                Text(Self.detail(line, calendarName: calendarName)).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canOpen(line) { Image(systemName: "chevron.right").font(Theme.Fonts.secondary).foregroundStyle(.tertiary) }
        }
        if canOpen(line) {
            Button { openLineID = line.id } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { openLineID == line.id }, set: { if !$0 { openLineID = nil } })) {
                    inspector(line).frame(width: 290, height: 360)
                }
        } else {
            content
        }
    }

    // A copy whose source is gone has no known time, so there is nothing to open.
    private func canOpen(_ line: SyncPreview.Line) -> Bool { line.startsAt != nil && line.endsAt != nil }

    private func inspector(_ line: SyncPreview.Line) -> some View {
        EventInspector(
            event: ScheduleEvent(
                id: line.id, calendarID: line.targetCalendarID, title: line.title ?? "Copy made earlier",
                startsAt: line.startsAt ?? .distantPast, endsAt: line.endsAt ?? .distantPast,
                isAllDay: line.isAllDay, isCopy: true),
            calendar: schedule.calendars.first { $0.id == line.targetCalendarID },
            colors: CalendarColors.shared, close: { openLineID = nil })
    }

    private func calendarName(_ id: String) -> String? {
        schedule.calendars.first { $0.id == id }.map { CalendarAliases.shared.name(for: $0.id, real: $0.name) }
    }

    // MARK: Text

    static func ordered(_ lines: [SyncPreview.Line]) -> [SyncPreview.Line] {
        lines.filter { $0.action == "remove" } + lines.filter { $0.action != "remove" }
    }

    static let uncheckedExplanation = SyncPreview.uncheckedExplanation

    static func label(_ line: SyncPreview.Line) -> String {
        line.isUnchecked ? "Not checked" : label(line.action)
    }

    static func label(_ action: String) -> String {
        switch action {
        case "create": "Add"
        case "update": "Update"
        case "remove": "Remove"
        default: "Repair"
        }
    }

    private static func color(_ line: SyncPreview.Line) -> Color {
        if line.isUnchecked { return .secondary }
        return switch line.action {
        case "remove": Theme.bad
        case "repair": Theme.caution
        default: .secondary
        }
    }

    /// Time, then where the event comes from and which copy is touched, then why.
    static func detail(_ line: SyncPreview.Line, calendarName: (String) -> String?) -> String {
        var parts: [String] = []
        if let start = line.startsAt {
            let day = start.formatted(.dateTime.weekday(.abbreviated).month().day())
            parts.append(line.isAllDay ? "\(day), all day" : "\(day), \(start.formatted(date: .omitted, time: .shortened))")
        }
        let target = calendarName(line.targetCalendarID)
        if let source = line.sourceCalendarID.flatMap(calendarName) {
            parts.append(target.map { "\(source) to \($0)" } ?? "from \(source)")
        } else if let target {
            parts.append("copy on \(target)")
        }
        if !line.isUnchecked { parts.append(line.reason) }
        return parts.joined(separator: " · ")
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    static func summaryLine(_ preview: SyncPreview) -> String {
        [
            ("to create", preview.creates), ("to update", preview.updates),
            ("to remove", preview.removals), ("to repair", preview.repairs),
            ("could not be checked", preview.unchecked),
        ]
        .filter { $0.1 > 0 }
        .map { "\($0.1) \($0.0)" }
        .joined(separator: ", ")
    }
}
