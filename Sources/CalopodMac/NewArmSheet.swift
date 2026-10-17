import CalopodCommands
import CalopodDomain
import SwiftUI

/// Builds one arm: where events come from, where they go and what the copies show.
struct NewArmSheet: View {
    let model: SetupModel
    let colors: CalendarColors

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewArmDraft

    init(model: SetupModel, colors: CalendarColors, draft: NewArmDraft = NewArmDraft()) {
        self.model = model
        self.colors = colors
        _draft = State(initialValue: draft)
    }

    private var groups: [ArmCalendarGroup] {
        NewArmDraft.groups(from: model.snapshot?.connections ?? [], aliases: model.aliases)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { fields }
            Divider()
            footer
        }
        .frame(width: 600, height: 640)
        .background(Theme.pane)
        .disabled(model.isBusy)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New arm").font(Theme.Fonts.heading)
            Text("Pick the calendars to copy from, the calendar to copy into, and what the copies show.")
                .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 18)
    }

    var fields: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let busy = model.busy { BusyLine(text: busy) }
            if let notice = model.notice { Banner(kind: .error, text: notice) }
            if NewArmDraft.sources(in: groups).isEmpty {
                Banner(kind: .info, text: "Choose at least one calendar on the Calendars screen first.")
            }
            nameField
            sources
            destination
            rule
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sections

    private var nameField: some View {
        section("Name", note: "Optional. Shown on the Arms page.") {
            TextField("Unnamed Arm", text: $draft.name).textFieldStyle(.roundedBorder)
        }
    }

    private var sources: some View {
        section("Copy from", note: "Choose one or more calendars.") {
            chipGroups(NewArmDraft.sources(in: groups)) { calendar in
                chip(calendar, selected: draft.sources.contains(calendar.id)) { draft.toggleSource(calendar.id) }
            }
        }
    }

    private var destination: some View {
        let open = draft.targets(in: groups)
        return section("Copy into", note: "One calendar you can write to. It can't also be a source.") {
            if open.isEmpty {
                Text("No writable calendar is left to choose.").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            } else {
                chipGroups(open) { calendar in
                    chip(calendar, selected: draft.target == calendar.id) { draft.target = calendar.id }
                }
            }
        }
    }

    private var rule: some View {
        section("What the copies show", note: nil) {
            HStack(alignment: .top, spacing: 10) {
                ruleCard(.busy, "Busy only", "Copies appear as plain Busy blocks. Titles, places and notes stay behind.")
                ruleCard(.fullDetails, "Full details", "Copies keep the title, place and notes of the original.")
            }
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            if let reason = draft.problem {
                Text(reason).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .accessibilityLabel("Cannot create yet. \(reason)")
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Create arm") { create() }
                .buttonStyle(.accentFilled)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil || model.isBusy)
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 14)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.Fonts.bodySemibold)
                if let note { Text(note).font(Theme.Fonts.secondary).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func chipGroups<Chip: View>(
        _ groups: [ArmCalendarGroup], @ViewBuilder chip: @escaping (ArmCalendar) -> Chip
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.label).font(Theme.Fonts.secondarySemibold).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) { ForEach(group.calendars) { chip($0) } }
                }
            }
        }
    }

    private func chip(_ calendar: ArmCalendar, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CappedWidth(limit: 260) {
                HStack(spacing: 6) {
                    Circle().fill(colors.color(for: calendar.id).color).frame(width: 9, height: 9)
                    Text(calendar.name).font(Theme.Fonts.chip).lineLimit(1).truncationMode(.tail)
                    if selected { Image(systemName: "checkmark").font(Theme.Fonts.tinyBold).foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, 12).frame(height: Theme.Control.chipHeight)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1))
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func ruleCard(_ value: ArmRuleMode, _ title: String, _ detail: String) -> some View {
        let selected = draft.rule == value
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        return Button { draft.rule = value } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                    Text(title).font(Theme.Fonts.bodySemibold)
                }
                Text(detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.paneLine, lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func create() {
        guard let target = draft.target, draft.problem == nil else { return }
        let draft = draft
        Task {
            await model.addArm(sources: Array(draft.sources), target: target, rule: draft.rule, name: draft.trimmedName)
            // A refused arm leaves its reason in the sheet; a saved one closes it.
            if model.notice == nil { dismiss() }
        }
    }
}
