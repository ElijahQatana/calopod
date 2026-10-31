import CalopodCommands
import CalopodDomain
import SwiftUI

/// One arm: its name and controls on top, then where its events come from and go.
struct ArmCard: View {
    let model: SetupModel
    let arm: SetupArm
    let colors: CalendarColors

    @State private var renaming = false
    @State private var confirmingRemoval = false
    @State private var editingLabel = false
    @State private var labelText = ""
    @State private var editingPadding = false
    @State private var padding = ArmPadding()

    private var ruleBinding: Binding<ArmRuleMode> {
        Binding(
            get: { arm.rule },
            set: { value in
                guard arm.canChangeRule else { return }
                if value == .label && arm.label == nil {
                    startEditingLabel()
                } else {
                    Task { await model.setRule(arm.id, value) }
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            flow
            if editingLabel { labelEditor }
            if editingPadding { paddingEditor }
            if confirmingRemoval { removalConfirm }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelFill(.inner, in: armCardShape)
        .overlay(armCardShape.strokeBorder(Theme.paneLine, lineWidth: 1))
        .disabled(model.isBusy)
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 10) {
            ArmTitle(model: model, arm: arm, editing: $renaming)
                .opacity(arm.isEnabled ? 1 : 0.6)
                .layoutPriority(1)
            Spacer(minLength: 4)
            ruleBadge
            filtersMenu
            overflowMenu
            Toggle("Enabled", isOn: Binding(
                get: { arm.isEnabled },
                set: { value in Task { await model.setArmEnabled(arm.id, value) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enabled")
                .accessibilityValue("\(arm.name), \(arm.isEnabled ? "on" : "off")")
        }
    }

    @ViewBuilder
    private var ruleBadge: some View {
        let label = HStack(spacing: 4) {
            Text(Self.ruleName(arm.rule))
            if arm.canChangeRule { Image(systemName: "chevron.down").font(Theme.Fonts.tinyBold) }
        }
        .font(Theme.Fonts.secondaryMedium)
        .padding(.horizontal, 12).frame(minHeight: Theme.Control.smallChipHeight)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
        .fixedSize()
        if arm.canChangeRule {
            Menu {
                Picker("Rule", selection: ruleBinding) {
                    Text("Busy only").tag(ArmRuleMode.busy)
                    Text("Label").tag(ArmRuleMode.label)
                    Text("Full details").tag(ArmRuleMode.fullDetails)
                }
                .pickerStyle(.inline)
            } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose what the copies show")
                .accessibilityLabel("Rule for \(arm.name)")
                .accessibilityValue(Self.ruleName(arm.rule))
        } else {
            label
                .help("The Main calendar always shows full details")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rule for \(arm.name)")
                .accessibilityValue("\(Self.ruleName(arm.rule)), fixed")
        }
    }

    private func filterBinding(_ keyPath: WritableKeyPath<ArmFilters, Bool>) -> Binding<Bool> {
        Binding(
            get: { arm.filters[keyPath: keyPath] },
            set: { value in
                var filters = arm.filters
                filters[keyPath: keyPath] = value
                Task { await model.setFilters(arm.id, filters) }
            })
    }

    private var filtersMenu: some View {
        let count = [arm.filters.skipDeclined, arm.filters.skipAllDay, arm.filters.skipDontClone].filter { $0 }.count
        return Menu {
            Toggle("Skip declined events", isOn: filterBinding(\.skipDeclined))
            Toggle("Skip all-day events", isOn: filterBinding(\.skipAllDay))
            Toggle("Skip events tagged #dontclone", isOn: filterBinding(\.skipDontClone))
        } label: {
            HStack(spacing: 4) {
                Text(count == 0 ? "Filters" : "Filters: \(count)")
                Image(systemName: "chevron.down").font(Theme.Fonts.tinyBold)
            }
            .font(Theme.Fonts.secondaryMedium)
            .padding(.horizontal, 12).frame(minHeight: Theme.Control.smallChipHeight)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which events this arm leaves out")
        .accessibilityLabel("Filters for \(arm.name)")
        .accessibilityValue(count == 0 ? "None" : "\(count) on")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Rename") { renaming = true }
            if arm.rule == .label { Button("Change label…") { startEditingLabel() } }
            if arm.rule != .fullDetails { Button("Padding…") { startEditingPadding() } }
            Divider()
            Button(arm.isMain ? "Remove Main calendar…" : "Remove…", role: .destructive) { confirmingRemoval = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.Fonts.bodySemibold)
                .foregroundStyle(.secondary)
                .frame(width: Theme.Control.height, height: Theme.Control.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions for \(arm.name)")
    }

    private var flow: some View {
        let sources = Array(zip(arm.sourceIDs, model.sourceNames(of: arm)))
        return HStack(alignment: .top, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(sources, id: \.0) { id, name in CalendarChip(name: name, color: colors.color(for: id).color) }
            }
            Image(systemName: "arrow.right")
                .font(Theme.Fonts.smallIcon)
                .foregroundStyle(.secondary)
                .frame(height: Theme.Control.chipHeight)
            CalendarChip(name: model.targetName(of: arm), color: colors.color(for: arm.targetID).color, isTarget: true)
        }
        .opacity(arm.isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copies from \(sources.map(\.1).joined(separator: ", ")) into \(model.targetName(of: arm))")
    }

    private func startEditingLabel() {
        labelText = arm.label ?? ""
        editingLabel = true
    }

    private var labelEditor: some View {
        let text = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 8) {
            TextField("Label, such as Personal", text: $labelText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Label for \(arm.name)")
            Button("Cancel") { editingLabel = false }.buttonStyle(.quiet)
            Button("Save") {
                editingLabel = false
                Task { await model.setRule(arm.id, .label, label: text) }
            }
            .buttonStyle(.quiet)
            .disabled(text.isEmpty)
        }
    }

    private func startEditingPadding() {
        padding = arm.padding
        editingPadding = true
    }

    private var paddingEditor: some View {
        HStack(spacing: 8) {
            Stepper("Before: \(padding.beforeMinutes) min", value: $padding.beforeMinutes, in: 0...ArmPadding.maxMinutes, step: 5)
            Stepper("After: \(padding.afterMinutes) min", value: $padding.afterMinutes, in: 0...ArmPadding.maxMinutes, step: 5)
            Toggle("In-person only", isOn: $padding.inPersonOnly)
                .help("Pad only events with a location and no meeting link")
            Spacer(minLength: 4)
            Button("Cancel") { editingPadding = false }.buttonStyle(.quiet)
            Button("Save") {
                editingPadding = false
                Task { await model.setPadding(arm.id, padding) }
            }
            .buttonStyle(.quiet)
        }
        .font(Theme.Fonts.secondary)
    }

    private var removalConfirm: some View {
        HStack(spacing: 8) {
            Text("Remove this arm? Events already copied stay put.").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { confirmingRemoval = false }.buttonStyle(.quiet)
            Button("Remove", role: .destructive) {
                confirmingRemoval = false
                Task { await model.removeArm(arm.id) }
            }
            .buttonStyle(.quiet)
        }
    }

    static func ruleName(_ rule: ArmRuleMode) -> String {
        switch rule {
        case .busy: "Busy only"
        case .label: "Label"
        case .fullDetails: "Full details"
        }
    }
}

/// A calendar as a small capsule with its color. The destination gets an outline.
struct CalendarChip: View {
    let name: String
    let color: Color
    var isTarget = false

    var body: some View {
        CappedWidth(limit: 280) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(name).font(Theme.Fonts.chip).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 12).frame(height: Theme.Control.chipHeight)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay { if isTarget { Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1) } }
        }
    }
}

/// Keeps a long name from stretching its capsule: the child is offered at most `limit` and
/// then sized to what it needs, unlike a flexible frame, which grows to fill the offer.
struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(offer(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: offer(proposal))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height)
    }
}

/// The arm's name. Double-click, the pencil or Rename edits it in place.
private struct ArmTitle: View {
    let model: SetupModel
    let arm: SetupArm
    @Binding var editing: Bool

    @State private var draft = ""
    @State private var problem: String?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($focused)
                    .onSubmit { Task { await commit(keepOpenOnError: true) } }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused && editing { Task { await commit(keepOpenOnError: false) } }
                    }
                if let problem { Text(problem).font(Theme.Fonts.secondary).foregroundStyle(Theme.badText) }
            } else {
                HStack(spacing: 6) {
                    Text(arm.name).font(Theme.Fonts.bodySemibold).lineLimit(1).truncationMode(.tail)
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.bare)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .help("Rename")
                        .accessibilityLabel("Rename \(arm.name)")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = true }
                .onHover { hovering = $0 }
                .contextMenu { Button("Rename") { editing = true } }
            }
        }
        .onChange(of: editing) { _, isEditing in
            if isEditing { begin() }
        }
    }

    private func begin() {
        draft = arm.name
        problem = nil
        focused = true
    }

    private func commit(keepOpenOnError: Bool) async {
        guard editing else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == arm.name { editing = false; return }
        if let message = await model.renameArm(arm.id, to: name) {
            if keepOpenOnError { problem = message; focused = true } else { editing = false }
        } else {
            editing = false
        }
    }
}
